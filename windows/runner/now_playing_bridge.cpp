#include "now_playing_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using std::chrono::duration_cast;
using std::chrono::milliseconds;

namespace wmc = winrt::Windows::Media::Control;
namespace streams = winrt::Windows::Storage::Streams;
namespace imaging = winrt::Windows::Graphics::Imaging;

using Manager = wmc::GlobalSystemMediaTransportControlsSessionManager;
using Session = wmc::GlobalSystemMediaTransportControlsSession;
using Properties = wmc::GlobalSystemMediaTransportControlsSessionMediaProperties;
using Status = wmc::GlobalSystemMediaTransportControlsSessionPlaybackStatus;

std::string Trim(std::string s) {
  const char* blanks = " \t\r\n";
  s.erase(0, s.find_first_not_of(blanks));
  s.erase(s.find_last_not_of(blanks) + 1);
  return s;
}

std::string Utf8(const winrt::hstring& s) { return winrt::to_string(s); }

const std::string* StringArg(const EncodableValue* args, const char* key) {
  const auto* map = std::get_if<EncodableMap>(args);
  if (!map) return nullptr;
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

int64_t IntArg(const EncodableValue* args, const char* key) {
  const auto* map = std::get_if<EncodableMap>(args);
  if (!map) return 0;
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) return 0;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<double>(&it->second)) return static_cast<int64_t>(*v);
  return 0;
}

// Lo que está sonando en una de las apps.
struct State {
  Session session{nullptr};
  Properties properties{nullptr};
  std::string app_id;
  std::string title;
  std::string artist;
  std::string album;
  int64_t duration_ms = 0;
  int64_t position_ms = 0;
  bool playing = false;
  std::chrono::steady_clock::time_point read_at;

  std::string Key() const { return app_id + "|" + title + "|" + artist; }

  int64_t PositionNow() const {
    if (!playing) return position_ms;
    auto elapsed = duration_cast<milliseconds>(std::chrono::steady_clock::now() - read_at);
    return position_ms + elapsed.count();
  }
};

// Lo último que se leyó de la línea de tiempo de una app, para saber si
// trae un dato nuevo o es el mismo de antes.
struct Anchor {
  std::string song;
  int64_t raw_position = 0;
  int64_t raw_updated = 0;  // LastUpdatedTime, en unidades de 100 ns
  bool playing = false;
  int64_t position_ms = 0;
  std::chrono::steady_clock::time_point read_at;

  int64_t PositionNow() const {
    if (!playing) return position_ms;
    auto elapsed = duration_cast<milliseconds>(std::chrono::steady_clock::now() - read_at);
    return position_ms + elapsed.count();
  }
};

std::vector<uint8_t> ReadAll(const streams::IRandomAccessStream& stream) {
  auto size = stream.Size();
  if (size == 0 || size > 20 * 1024 * 1024) return {};
  auto length = static_cast<uint32_t>(size);
  streams::DataReader reader(stream.GetInputStreamAt(0));
  reader.LoadAsync(length).get();
  std::vector<uint8_t> bytes(length);
  reader.ReadBytes(bytes);
  return bytes;
}

// JPEG de 600 px como máximo: algunas apps dan la carátula en tamaño
// original y mandarla entera en cada actualización hace todo más lento.
std::vector<uint8_t> Shrink(std::vector<uint8_t> bytes) {
  try {
    streams::InMemoryRandomAccessStream input;
    streams::DataWriter writer(input);
    writer.WriteBytes(bytes);
    writer.StoreAsync().get();
    writer.DetachStream();
    input.Seek(0);
    auto decoder = imaging::BitmapDecoder::CreateAsync(input).get();
    uint32_t width = decoder.PixelWidth();
    uint32_t height = decoder.PixelHeight();
    uint32_t longest = std::max(width, height);
    if (longest <= 600) return bytes;
    double scale = 600.0 / longest;
    auto bitmap = decoder
                      .GetSoftwareBitmapAsync(imaging::BitmapPixelFormat::Bgra8,
                                              imaging::BitmapAlphaMode::Ignore)
                      .get();
    streams::InMemoryRandomAccessStream output;
    auto encoder =
        imaging::BitmapEncoder::CreateAsync(imaging::BitmapEncoder::JpegEncoderId(), output)
            .get();
    encoder.SetSoftwareBitmap(bitmap);
    encoder.BitmapTransform().ScaledWidth(std::max(1u, static_cast<uint32_t>(width * scale)));
    encoder.BitmapTransform().ScaledHeight(std::max(1u, static_cast<uint32_t>(height * scale)));
    encoder.BitmapTransform().InterpolationMode(imaging::BitmapInterpolationMode::Fant);
    encoder.FlushAsync().get();
    auto shrunk = ReadAll(output);
    return shrunk.empty() ? bytes : shrunk;
  } catch (...) {
    return bytes;
  }
}

// Hora (ms desde 1970) en que se leyó la posición, para que la letra no
// arranque atrasada por lo que tarda el mensaje en llegar a Dart.
int64_t CapturedAtMs(std::chrono::steady_clock::time_point read_at) {
  auto age = std::chrono::steady_clock::now() - read_at;
  auto at = std::chrono::system_clock::now() - age;
  return duration_cast<milliseconds>(at.time_since_epoch()).count();
}

std::vector<uint8_t> ReadThumbnail(const Properties& properties) {
  auto reference = properties.Thumbnail();
  if (!reference) return {};
  auto stream = reference.OpenReadAsync().get();
  return ReadAll(stream);
}

}  // namespace

struct NowPlayingBridge::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> methods;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
  // Solo desde el hilo de la ventana.
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;

  // Compartido entre los dos hilos (con [mutex]).
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<std::function<void()>> tasks;
  std::optional<EncodableValue> outbox;
  bool listening = false;
  bool force_poll = false;
  bool stopping = false;

  // Solo desde el hilo de consultas.
  Manager manager{nullptr};
  std::optional<std::string> preferred;
  std::string last_playing_app;
  std::optional<State> last_emitted;
  std::string artwork_key;
  std::vector<uint8_t> artwork;
  std::vector<uint8_t> previous_artwork;
  int artwork_tries = 0;
  std::map<std::string, Anchor> anchors;  // por app

  std::thread thread;

  explicit Impl(HWND window) : window(window) {}

  // ------------------------------------------------- hilo de la ventana

  void Enqueue(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      tasks.push_back(std::move(task));
    }
    wake.notify_one();
  }

  void RequestPoll() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      force_poll = true;
    }
    wake.notify_one();
  }

  void HandleMethod(const flutter::MethodCall<EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto& method = call.method_name();
    const auto* args = call.arguments();
    if (method == "isNotificationAccessGranted") {
      // En Windows no hace falta ningún permiso.
      result->Success(EncodableValue(true));
    } else if (method == "refresh") {
      RequestPoll();
      result->Success();
    } else if (method == "play" || method == "pause" || method == "skipToNext" ||
               method == "skipToPrevious") {
      Enqueue([this, method] {
        Command(method, 0);
        PollNow(true);
      });
      result->Success();
    } else if (method == "seekTo") {
      int64_t ms = IntArg(args, "positionMs");
      Enqueue([this, ms] {
        Command("seekTo", ms);
        PollNow(true);
      });
      result->Success();
    } else if (method == "setPreferredPackage") {
      const std::string* package = StringArg(args, "packageName");
      std::optional<std::string> value;
      if (package) value = *package;
      Enqueue([this, value] {
        preferred = value;
        PollNow(true);
      });
      result->Success();
    } else if (method == "openNotificationAccessSettings" || method == "setLiveLyrics" ||
               method == "setLiveOffset" || method == "clearLiveLyrics" ||
               method == "setLiveOptions") {
      // La letra fuera de la app todavía no existe en Windows.
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  void Flush() {
    std::optional<EncodableValue> value;
    {
      std::lock_guard<std::mutex> lock(mutex);
      value.swap(outbox);
    }
    if (value && sink) sink->Success(*value);
  }

  // ------------------------------------------------- hilo de consultas

  void Run() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    while (true) {
      std::function<void()> task;
      bool poll = false;
      bool force = false;
      {
        std::unique_lock<std::mutex> lock(mutex);
        // Sondeo liviano cada medio segundo (detecta canción nueva, pausa
        // y saltos dentro de la canción); los pedidos de Dart, enseguida.
        wake.wait_for(lock, milliseconds(500),
                      [this] { return stopping || !tasks.empty() || force_poll; });
        if (stopping) break;
        if (!tasks.empty()) {
          task = std::move(tasks.front());
          tasks.pop_front();
        }
        force = force_poll;
        force_poll = false;
        poll = listening;
      }
      try {
        if (task) {
          task();
        } else if (poll) {
          PollNow(force);
        }
      } catch (...) {
        // Una app que se cerró a mitad de la consulta: se reintenta en la
        // vuelta siguiente.
      }
    }
    // Los objetos de Windows se sueltan antes de cerrar el apartamento.
    last_emitted.reset();
    manager = nullptr;
    winrt::uninit_apartment();
  }

  bool EnsureManager() {
    if (manager) return true;
    try {
      manager = Manager::RequestAsync().get();
    } catch (...) {
      manager = nullptr;
    }
    return static_cast<bool>(manager);
  }

  std::optional<State> Read(const Session& session) {
    try {
      auto info = session.GetPlaybackInfo();
      auto status = info.PlaybackStatus();
      if (status == Status::Closed || status == Status::Stopped) return std::nullopt;
      auto properties = session.TryGetMediaPropertiesAsync().get();
      State s;
      s.session = session;
      s.properties = properties;
      s.app_id = Utf8(session.SourceAppUserModelId());
      s.title = Trim(Utf8(properties.Title()));
      if (s.title.empty()) return std::nullopt;
      s.artist = Trim(Utf8(properties.Artist()));
      if (s.artist.empty()) s.artist = Trim(Utf8(properties.AlbumArtist()));
      s.album = Trim(Utf8(properties.AlbumTitle()));
      s.playing = status == Status::Playing;

      auto timeline = session.GetTimelineProperties();
      s.duration_ms = duration_cast<milliseconds>(timeline.EndTime() - timeline.StartTime()).count();
      s.read_at = std::chrono::steady_clock::now();
      int64_t raw_position =
          duration_cast<milliseconds>(timeline.Position() - timeline.StartTime()).count();
      int64_t raw_updated = timeline.LastUpdatedTime().time_since_epoch().count();
      int64_t since =
          duration_cast<milliseconds>(winrt::clock::now() - timeline.LastUpdatedTime()).count();
      bool since_ok = since >= 0 && since < 24LL * 60 * 60 * 1000;
      std::string song = s.title + "|" + s.artist;

      // La posición es la de la última vez que la app la informó, y
      // Spotify la informa poco (al cambiar de tema, pausar o saltar). Si
      // se le suma siempre lo que pasó desde LastUpdatedTime, la letra se
      // corre: al reanudar después de una pausa Spotify no siempre
      // actualiza esa hora y la pausa entera se contaba como reproducida.
      // Por eso solo se usa un dato cuando es nuevo; si es el mismo de la
      // vuelta anterior, sigue nuestro propio reloj.
      auto found = anchors.find(s.app_id);
      const Anchor* prev = found == anchors.end() ? nullptr : &found->second;
      bool same_data = prev && prev->raw_position == raw_position &&
                       prev->raw_updated == raw_updated;
      int64_t position;
      if (!s.playing) {
        // Si al pausar la app no informó la posición, vale la que veníamos
        // contando nosotros.
        position = prev && same_data && prev->playing && prev->song == song
                       ? prev->PositionNow()
                       : raw_position;
      } else if (!prev) {
        // Primera vez que se ve esta app: no hay otra que confiar en la hora.
        position = raw_position + (since_ok ? since : 0);
      } else if (prev->song != song) {
        // Tema nuevo. Si la línea de tiempo todavía es la del anterior,
        // el tema acaba de empezar (lo vimos cambiar en esta vuelta).
        position = same_data ? 0 : raw_position + (since_ok && since < 5000 ? since : 0);
      } else if (!same_data) {
        // Dato nuevo (seek, play, pausa...): pasó hace a lo sumo una vuelta.
        position = raw_position + (since_ok && since < 5000 ? since : 0);
      } else if (prev->playing) {
        position = prev->PositionNow();
      } else {
        // Se reanudó sin que la app actualice la línea de tiempo: sigue
        // desde donde quedó pausada.
        position = prev->position_ms;
      }
      if (s.duration_ms > 0) position = std::min(position, s.duration_ms);
      s.position_ms = std::max<int64_t>(0, position);

      Anchor& anchor = anchors[s.app_id];
      anchor.song = song;
      anchor.raw_position = raw_position;
      anchor.raw_updated = raw_updated;
      anchor.playing = s.playing;
      anchor.position_ms = s.position_ms;
      anchor.read_at = s.read_at;
      return s;
    } catch (...) {
      return std::nullopt;
    }
  }

  void PollNow(bool force) {
    if (!EnsureManager()) return;
    std::vector<State> states;
    for (const auto& session : manager.GetSessions()) {
      if (auto s = Read(session)) states.push_back(std::move(*s));
    }
    for (const auto& s : states) {
      if (s.playing) {
        last_playing_app = s.app_id;
        break;
      }
    }

    std::string current_app;
    try {
      if (auto current = manager.GetCurrentSession()) {
        current_app = Utf8(current.SourceAppUserModelId());
      }
    } catch (...) {
    }

    auto find = [&](auto predicate) -> const State* {
      for (const auto& s : states) {
        if (predicate(s)) return &s;
      }
      return nullptr;
    };
    const State* chosen = nullptr;
    if (preferred) chosen = find([&](const State& s) { return s.app_id == *preferred; });
    if (!chosen && last_emitted) {
      chosen = find([&](const State& s) { return s.playing && s.app_id == last_emitted->app_id; });
    }
    if (!chosen) chosen = find([&](const State& s) { return s.playing && s.app_id == current_app; });
    if (!chosen) chosen = find([](const State& s) { return s.playing; });
    if (!chosen) chosen = find([&](const State& s) { return s.app_id == last_playing_app; });
    if (!chosen && !states.empty()) chosen = &states.front();

    if (!chosen) {
      if (last_emitted || force) {
        last_emitted.reset();
        Post(EncodableValue());
      }
      return;
    }
    const State& s = *chosen;

    // Carátula: Windows a veces sigue dando la de la canción anterior un
    // momento después del cambio, o todavía ninguna. Se reintenta unas
    // vueltas hasta que llegue una distinta.
    bool artwork_arrived = false;
    if (artwork_key != s.Key()) {
      if (!artwork.empty()) previous_artwork = std::move(artwork);
      artwork.clear();
      artwork_key = s.Key();
      artwork_tries = 0;
    }
    if (artwork.empty() && artwork_tries < 8) {
      artwork_tries++;
      try {
        auto bytes = ReadThumbnail(s.properties);
        bool stale = bytes == previous_artwork && artwork_tries < 8;
        if (!bytes.empty() && !stale) {
          artwork = Shrink(std::move(bytes));
          artwork_arrived = true;
        }
      } catch (...) {
      }
    }

    if (!force && !artwork_arrived && last_emitted && last_emitted->Key() == s.Key() &&
        last_emitted->playing == s.playing &&
        std::abs(last_emitted->PositionNow() - s.position_ms) < 300) {
      return;
    }
    Emit(s, states);
  }

  void Emit(const State& s, const std::vector<State>& states) {
    last_emitted = s;
    EncodableList players;
    for (const auto& p : states) {
      players.push_back(EncodableValue(EncodableMap{
          {EncodableValue("packageName"), EncodableValue(p.app_id)},
          {EncodableValue("title"), EncodableValue(p.title)},
          {EncodableValue("artist"), EncodableValue(p.artist)},
          {EncodableValue("isPlaying"), EncodableValue(p.playing)},
      }));
    }
    EncodableMap map{
        {EncodableValue("title"), EncodableValue(s.title)},
        {EncodableValue("artist"), EncodableValue(s.artist)},
        {EncodableValue("album"), EncodableValue(s.album)},
        {EncodableValue("durationMs"), EncodableValue(s.duration_ms)},
        {EncodableValue("positionMs"), EncodableValue(s.position_ms)},
        {EncodableValue("capturedAtMs"), EncodableValue(CapturedAtMs(s.read_at))},
        {EncodableValue("isPlaying"), EncodableValue(s.playing)},
        {EncodableValue("playbackSpeed"), EncodableValue(1.0)},
        {EncodableValue("packageName"), EncodableValue(s.app_id)},
        {EncodableValue("nextTitle"), EncodableValue(std::string())},
        {EncodableValue("nextArtist"), EncodableValue(std::string())},
        {EncodableValue("nextDurationMs"), EncodableValue(0)},
        {EncodableValue("players"), EncodableValue(players)},
    };
    if (artwork_key == s.Key() && !artwork.empty()) {
      map[EncodableValue("albumArt")] = EncodableValue(artwork);
    }
    Post(EncodableValue(map));
  }

  void Post(EncodableValue value) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      outbox = std::move(value);
    }
    PostMessage(window, kNowPlayingMessage, 0, 0);
  }

  // Le manda el comando a la app que se está siguiendo.
  void Command(const std::string& method, int64_t position_ms) {
    if (!EnsureManager()) return;
    std::string target = last_emitted ? last_emitted->app_id : last_playing_app;
    Session session{nullptr};
    for (const auto& candidate : manager.GetSessions()) {
      if (Utf8(candidate.SourceAppUserModelId()) == target) {
        session = candidate;
        break;
      }
    }
    if (!session) session = manager.GetCurrentSession();
    if (!session) return;
    if (method == "play") {
      session.TryPlayAsync().get();
    } else if (method == "pause") {
      session.TryPauseAsync().get();
    } else if (method == "skipToNext") {
      session.TrySkipNextAsync().get();
    } else if (method == "skipToPrevious") {
      session.TrySkipPreviousAsync().get();
    } else if (method == "seekTo") {
      // En unidades de 100 ns.
      session.TryChangePlaybackPositionAsync(position_ms * 10000).get();
    }
  }
};

NowPlayingBridge::NowPlayingBridge(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(window)) {
  Impl* impl = impl_.get();
  impl->methods = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "io.letras.app/now_playing", &flutter::StandardMethodCodec::GetInstance());
  impl->methods->SetMethodCallHandler(
      [impl](const auto& call, auto result) { impl->HandleMethod(call, std::move(result)); });

  impl->events = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "io.letras.app/now_playing_stream",
      &flutter::StandardMethodCodec::GetInstance());
  impl->events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [impl](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        impl->sink = std::move(events);
        {
          std::lock_guard<std::mutex> lock(impl->mutex);
          impl->listening = true;
          impl->force_poll = true;
        }
        impl->wake.notify_one();
        return nullptr;
      },
      [impl](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        impl->sink.reset();
        std::lock_guard<std::mutex> lock(impl->mutex);
        impl->listening = false;
        return nullptr;
      }));

  impl->thread = std::thread([impl] { impl->Run(); });
}

NowPlayingBridge::~NowPlayingBridge() {
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stopping = true;
  }
  impl_->wake.notify_one();
  if (impl_->thread.joinable()) impl_->thread.join();
  impl_->methods->SetMethodCallHandler(nullptr);
  impl_->events->SetStreamHandler(nullptr);
}

void NowPlayingBridge::Flush() { impl_->Flush(); }
