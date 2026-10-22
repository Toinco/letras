#ifndef RUNNER_NOW_PLAYING_BRIDGE_H_
#define RUNNER_NOW_PLAYING_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// Versión Windows de lo que en Android hace MediaSessionBridge y en la Mac
// NowPlayingBridge.swift: lee los controles multimedia del sistema (los
// mismos del cuadro que aparece al subir el volumen), así que detecta
// Spotify, el navegador y casi cualquier reproductor, y se lo pasa a Dart
// por los mismos canales.
//
// Las consultas a Windows corren en un hilo aparte; cuando hay algo para
// Dart, le avisa a la ventana con kNowPlayingMessage y la ventana llama a
// Flush() desde su hilo (el único desde donde se le puede hablar a Flutter).
class NowPlayingBridge {
 public:
  static constexpr UINT kNowPlayingMessage = WM_APP + 1;

  NowPlayingBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~NowPlayingBridge();

  NowPlayingBridge(const NowPlayingBridge&) = delete;
  NowPlayingBridge& operator=(const NowPlayingBridge&) = delete;

  // Manda a Dart lo que dejó el hilo de consultas.
  void Flush();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_NOW_PLAYING_BRIDGE_H_
