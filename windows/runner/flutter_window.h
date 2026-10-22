#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

#include "now_playing_bridge.h"
#include "win32_window.h"

// Identifica el WM_COPYDATA con el que una segunda copia de Letras le pasa
// a esta un enlace io.letras.app://... (o nada, solo para traerla al frente).
constexpr ULONG_PTR kLinkCopyDataId = 0x4C455452;  // "LETR"

// La ventana de Letras con Flutter adentro, más los canales propios de
// Windows: qué está sonando, la vuelta del login de Spotify y la pantalla
// completa.
class FlutterWindow : public Win32Window {
 public:
  // [initial_link]: el enlace con el que se abrió la app, si vino uno.
  FlutterWindow(const flutter::DartProject& project, std::optional<std::string> initial_link);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void SetUpChannels();
  void DeliverLink(const std::string& link);
  void ToggleFullScreen();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<NowPlayingBridge> now_playing_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> redirect_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> redirect_sink_;
  std::optional<std::string> pending_link_;

  bool full_screen_ = false;
  WINDOWPLACEMENT saved_placement_{};
  LONG_PTR saved_style_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
