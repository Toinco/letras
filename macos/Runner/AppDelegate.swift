import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var redirectSink: FlutterEventSink?
  private var pendingRedirect: String?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// El login de Spotify vuelve con io.letras.app://spotify-callback?code=...
  /// (el mismo enlace que en Android) y se lo pasamos a Dart.
  func attachSpotifyRedirect(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "io.letras.app/spotify_redirect", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "io.letras.app" {
      if let sink = redirectSink {
        sink(url.absoluteString)
      } else {
        pendingRedirect = url.absoluteString
      }
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    redirectSink = events
    if let pending = pendingRedirect {
      pendingRedirect = nil
      events(pending)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    redirectSink = nil
    return nil
  }
}
