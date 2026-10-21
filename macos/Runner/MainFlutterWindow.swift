import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var nowPlaying: NowPlayingBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // La interfaz está pensada para el teléfono: una ventana angosta y alta
    // se ve como corresponde, y igual se puede agrandar.
    self.title = "Letras"
    self.minSize = NSSize(width: 360, height: 560)
    self.setContentSize(NSSize(width: 440, height: 820))
    self.center()
    self.setFrameAutosaveName("Letras")

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    nowPlaying = NowPlayingBridge(messenger: messenger)
    (NSApp.delegate as? AppDelegate)?.attachSpotifyRedirect(messenger: messenger)

    super.awakeFromNib()
  }
}
