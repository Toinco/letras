import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  /// Alto de la barra de título (donde están los tres botones). Dart deja
  /// ese espacio libre arriba; ver `MacWindowInsets`.
  static let titleBarHeight: CGFloat = 28

  private var nowPlaying: NowPlayingBridge?
  private var windowChannel: FlutterMethodChannel?
  private var dragStrip: WindowDragStrip?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .black
    self.contentViewController = flutterViewController

    // Barra de título transparente: el contenido (y el fondo difuminado de
    // la carátula) llega hasta arriba, como en Música.
    self.title = "Letras"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.appearance = NSAppearance(named: .darkAqua)
    self.backgroundColor = .black
    self.tabbingMode = .disallowed

    // La interfaz está pensada para el teléfono: arranca angosta y alta,
    // y al agrandarla pasa al diseño de escritorio.
    self.minSize = NSSize(width: 380, height: 560)
    self.setContentSize(NSSize(width: 1100, height: 760))
    self.center()
    self.setFrameAutosaveName("Letras")

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    nowPlaying = NowPlayingBridge(messenger: messenger)
    (NSApp.delegate as? AppDelegate)?.attachSpotifyRedirect(messenger: messenger)

    windowChannel = FlutterMethodChannel(name: "io.letras.app/window", binaryMessenger: messenger)
    windowChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "isFullScreen":
        result(self?.styleMask.contains(.fullScreen) ?? false)
      case "toggleFullScreen":
        self?.toggleFullScreen(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.delegate = self

    // Flutter se queda con los clics de toda la ventana: esta franja
    // invisible arriba permite arrastrarla y hacer doble clic para ampliarla.
    let content = flutterViewController.view
    let strip = WindowDragStrip(frame: NSRect(
      x: 0, y: content.bounds.height - Self.titleBarHeight,
      width: content.bounds.width, height: Self.titleBarHeight))
    strip.autoresizingMask = [.width, .minYMargin]
    content.addSubview(strip)
    dragStrip = strip

    super.awakeFromNib()
  }

  // En pantalla completa la barra de título se esconde: la franja también.
  func windowDidEnterFullScreen(_ notification: Notification) {
    dragStrip?.isHidden = true
    windowChannel?.invokeMethod("fullScreenChanged", arguments: true)
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    dragStrip?.isHidden = false
    windowChannel?.invokeMethod("fullScreenChanged", arguments: false)
  }
}

/// Franja transparente sobre la barra de título.
final class WindowDragStrip: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      // Respeta la preferencia del sistema (ampliar o minimizar).
      let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
      if action == "Minimize" {
        window?.performMiniaturize(nil)
      } else if action != "None" {
        window?.performZoom(nil)
      }
      return
    }
    window?.performDrag(with: event)
  }
}
