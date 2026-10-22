#include "flutter_window.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Tamaño mínimo de la ventana (en píxeles lógicos), como en la Mac.
constexpr int kMinWidth = 380;
constexpr int kMinHeight = 560;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::optional<std::string> initial_link)
    : project_(project), pending_link_(std::move(initial_link)) {
  saved_placement_.length = sizeof(WINDOWPLACEMENT);
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetUpChannels();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();

  now_playing_ = std::make_unique<NowPlayingBridge>(messenger, GetHandle());

  // Pantalla completa (modo karaoke y ⇧Ctrl+F).
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "io.letras.app/window", codec);
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "isFullScreen") {
      result->Success(flutter::EncodableValue(full_screen_));
    } else if (call.method_name() == "toggleFullScreen") {
      ToggleFullScreen();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });

  // El login de Spotify vuelve con io.letras.app://spotify-callback?code=...
  // (lo registra main.cpp) y se lo pasamos a Dart.
  redirect_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "io.letras.app/spotify_redirect", codec);
  redirect_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            redirect_sink_ = std::move(events);
            if (pending_link_) {
              redirect_sink_->Success(flutter::EncodableValue(*pending_link_));
              pending_link_.reset();
            }
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            redirect_sink_.reset();
            return nullptr;
          }));
}

void FlutterWindow::DeliverLink(const std::string& link) {
  if (link.rfind("io.letras.app:", 0) == 0) {
    if (redirect_sink_) {
      redirect_sink_->Success(flutter::EncodableValue(link));
    } else {
      pending_link_ = link;
    }
  }
  HWND hwnd = GetHandle();
  if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ToggleFullScreen() {
  HWND hwnd = GetHandle();
  if (!full_screen_) {
    saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    GetWindowPlacement(hwnd, &saved_placement_);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_ & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
    const RECT& r = monitor.rcMonitor;
    SetWindowPos(hwnd, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
    SetWindowPlacement(hwnd, &saved_placement_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  full_screen_ = !full_screen_;
  window_channel_->InvokeMethod("fullScreenChanged",
                                std::make_unique<flutter::EncodableValue>(full_screen_));
}

void FlutterWindow::OnDestroy() {
  now_playing_ = nullptr;
  redirect_sink_ = nullptr;
  if (redirect_channel_) redirect_channel_->SetStreamHandler(nullptr);
  if (window_channel_) window_channel_->SetMethodCallHandler(nullptr);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case NowPlayingBridge::kNowPlayingMessage:
      if (now_playing_) now_playing_->Flush();
      return 0;
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data && data->dwData == kLinkCopyDataId) {
        std::string link(static_cast<const char*>(data->lpData), data->cbData);
        DeliverLink(link);
        return TRUE;
      }
      break;
    }
    case WM_GETMINMAXINFO: {
      double scale = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale);
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
