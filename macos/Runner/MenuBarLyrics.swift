import Cocoa

/// La línea que se está cantando, arriba en la barra de menú. Es el
/// equivalente Mac de la notificación con la letra de Android: se prende
/// con el mismo ajuste ("Letra fuera de la app").
final class MenuBarLyrics: NSObject {
  var positionProvider: (() -> (title: String, artist: String, positionMs: Int, isPlaying: Bool, readAt: Date)?)?

  var enabled = false {
    didSet { if enabled != oldValue { refreshVisibility() } }
  }

  var offsetMs = 0

  private var item: NSStatusItem?
  private var timer: Timer?
  private var title = ""
  private var artist = ""
  private var lines: [(ms: Int, text: String)] = []
  private var shown: String?

  private static let maxChars = 60

  func setLyrics(title: String, artist: String, lines: [(Int, String)], offsetMs: Int) {
    self.title = title
    self.artist = artist
    self.lines = lines.map { (ms: $0.0, text: $0.1) }
    self.offsetMs = offsetMs
    refreshVisibility()
  }

  private func refreshVisibility() {
    let show = enabled && !title.isEmpty
    if show && item == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.target = self
      item.button?.action = #selector(openApp)
      self.item = item
      timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    } else if !show, let item = item {
      NSStatusBar.system.removeStatusItem(item)
      self.item = nil
      timer?.invalidate()
      timer = nil
      shown = nil
    }
    tick()
  }

  @objc private func openApp() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }

  private func tick() {
    guard let button = item?.button else { return }
    var text = "\(title) · \(artist)"
    if let now = positionProvider?(), now.title == title, !lines.isEmpty {
      let elapsed = now.isPlaying ? Int(Date().timeIntervalSince(now.readAt) * 1000) : 0
      let pos = now.positionMs + elapsed + offsetMs
      if let line = lines.last(where: { $0.ms <= pos }) {
        text = line.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { text = "♪" }
      } else {
        text = "♪"
      }
    }
    if text.count > Self.maxChars { text = String(text.prefix(Self.maxChars - 1)) + "…" }
    if text != shown {
      shown = text
      button.title = text
      button.toolTip = "\(title) · \(artist)"
    }
  }
}
