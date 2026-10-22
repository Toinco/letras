import Cocoa
import FlutterMacOS
import ImageIO

/// Versión Mac de lo que en Android hace MediaSessionBridge: averigua qué
/// suena en Spotify o en Música (Apple Music) preguntándoles por AppleScript,
/// y se lo pasa a Dart por los mismos canales que usa Android.
///
/// Nunca abre una app de música que esté cerrada: antes de preguntarle se
/// fija que esté corriendo. La primera vez macOS pide permiso ("Letras
/// quiere controlar Spotify").
final class NowPlayingBridge: NSObject, FlutterStreamHandler {
  private struct Player {
    let bundleId: String
    let name: String
    let launchName: String
  }

  private struct State {
    let bundleId: String
    let title: String
    let artist: String
    let album: String
    let durationMs: Int
    let positionMs: Int
    let isPlaying: Bool
    let artworkUrl: String?
    let nextTitle: String?
    let nextArtist: String?
    let nextDurationMs: Int
    let readAt: Date

    var key: String { "\(bundleId)|\(title)|\(artist)" }

    func positionNow() -> Int {
      guard isPlaying else { return positionMs }
      return positionMs + Int(Date().timeIntervalSince(readAt) * 1000)
    }
  }

  private static let players = [
    Player(bundleId: "com.spotify.client", name: "Spotify", launchName: "Spotify"),
    Player(bundleId: "com.apple.Music", name: "Música", launchName: "Music"),
  ]

  private static let spotifyScript = """
    with timeout of 3 seconds
      tell application id "com.spotify.client"
        set t to current track
        return {name of t, artist of t, album of t, duration of t, player position, player state as string, artwork url of t}
      end tell
    end timeout
    """

  private static let musicScript = """
    with timeout of 3 seconds
      tell application id "com.apple.Music"
        set t to current track
        -- La próxima de la lista (si se está escuchando una lista o un
        -- álbum), para buscar su letra por adelantado.
        set nextName to ""
        set nextArtistName to ""
        set nextDur to 0
        try
          set nextTrack to track ((index of t) + 1) of current playlist
          set nextName to name of nextTrack
          set nextArtistName to artist of nextTrack
          set nextDur to (duration of nextTrack) * 1000
        end try
        return {name of t, artist of t, album of t, (duration of t) * 1000, player position, player state as string, nextName, nextArtistName, nextDur}
      end tell
    end timeout
    """

  private static let musicArtworkScript = """
    with timeout of 3 seconds
      tell application id "com.apple.Music" to return raw data of artwork 1 of current track
    end timeout
    """

  private let queue = DispatchQueue(label: "io.letras.app.nowplaying")
  private var ticks = 0
  private var sink: FlutterEventSink?
  private var timer: Timer?
  private var compiled: [String: NSAppleScript] = [:]

  // Solo se tocan desde [queue].
  private var preferred: String?
  private var lastPlayingBundle: String?
  private var lastEmitted: State?
  private var lastStates: [State] = []
  private var artwork: (key: String, data: Data?)?
  private var artworkLoading: String?

  /// Lo que se está mostrando (para la letra en la barra de menú).
  private(set) var current: (title: String, artist: String, positionMs: Int, isPlaying: Bool, readAt: Date)?

  let menuBar = MenuBarLyrics()

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let methods = FlutterMethodChannel(name: "io.letras.app/now_playing", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    FlutterEventChannel(name: "io.letras.app/now_playing_stream", binaryMessenger: messenger)
      .setStreamHandler(self)
    menuBar.positionProvider = { [weak self] in self?.current }

    // Spotify y Música avisan cuando cambia la canción o se pausa: así se
    // entera al instante, sin esperar al próximo sondeo.
    let center = DistributedNotificationCenter.default()
    for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
      center.addObserver(self, selector: #selector(playerChanged), name: Notification.Name(name), object: nil)
    }
  }

  @objc private func playerChanged() {
    poll(force: false)
  }

  // MARK: - Canal de métodos

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "isNotificationAccessGranted":
      // En la Mac no hace falta un permiso previo: macOS lo pide solo la
      // primera vez que le preguntamos a Spotify o a Música.
      result(true)
    case "openNotificationAccessSettings":
      let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
      NSWorkspace.shared.open(URL(string: url)!)
      result(nil)
    case "refresh":
      poll(force: true)
      result(nil)
    case "play":
      command("play", result: result)
    case "pause":
      command("pause", result: result)
    case "skipToNext":
      command("next track", result: result)
    case "skipToPrevious":
      command("previous track", result: result)
    case "seekTo":
      let ms = (args?["positionMs"] as? NSNumber)?.doubleValue ?? 0
      command("set player position to \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), ms / 1000))", result: result)
    case "setPreferredPackage":
      let pkg = args?["packageName"] as? String
      queue.async {
        self.preferred = pkg
        self.pollNow(force: true)
      }
      result(nil)
    case "setLiveLyrics":
      let lines = (args?["lines"] as? [[Any]] ?? []).compactMap { pair -> (Int, String)? in
        guard pair.count == 2, let ms = (pair[0] as? NSNumber)?.intValue, let text = pair[1] as? String
        else { return nil }
        return (ms, text)
      }
      menuBar.setLyrics(
        title: args?["title"] as? String ?? "",
        artist: args?["artist"] as? String ?? "",
        lines: lines,
        offsetMs: (args?["offsetMs"] as? NSNumber)?.intValue ?? 0)
      result(nil)
    case "setLiveOffset":
      menuBar.offsetMs = (args?["offsetMs"] as? NSNumber)?.intValue ?? 0
      result(nil)
    case "clearLiveLyrics":
      menuBar.setLyrics(title: "", artist: "", lines: [], offsetMs: 0)
      result(nil)
    case "setLiveOptions":
      menuBar.enabled = args?["notification"] as? Bool ?? false
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Le manda [verb] a la app que se está siguiendo.
  private func command(_ verb: String, result: @escaping FlutterResult) {
    queue.async {
      if let id = self.lastEmitted?.bundleId ?? self.lastPlayingBundle, self.isRunning(id) {
        let source = "with timeout of 3 seconds\ntell application id \"\(id)\" to \(verb)\nend timeout"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
      }
      // Que la UI se entere ya de la pausa o del salto.
      self.pollNow(force: true)
      DispatchQueue.main.async { result(nil) }
    }
  }

  // MARK: - Stream

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    poll(force: true)
    // Sondeo liviano: detecta saltos dentro de la canción (que no siempre
    // vienen con aviso) y corrige la posición. Una vez por segundo, y cada
    // medio segundo cuando la canción está por terminar: así la siguiente se
    // detecta enseguida (antes se veía con unos segundos de atraso).
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      self.queue.async {
        self.ticks += 1
        if self.ticks % 2 == 0 || self.nearEnd() { self.pollNow(force: false) }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }

  private func poll(force: Bool) {
    queue.async { self.pollNow(force: force) }
  }

  private func isRunning(_ bundleId: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
  }

  private func run(_ source: String) -> NSAppleEventDescriptor? {
    let script = compiled[source] ?? {
      let s = NSAppleScript(source: source)!
      compiled[source] = s
      return s
    }()
    var error: NSDictionary?
    let out = script.executeAndReturnError(&error)
    return error == nil ? out : nil
  }

  private func read(_ player: Player) -> State? {
    guard isRunning(player.bundleId) else { return nil }
    let isSpotify = player.bundleId == "com.spotify.client"
    guard let list = run(isSpotify ? Self.spotifyScript : Self.musicScript),
          list.numberOfItems >= 6 else { return nil }
    func text(_ i: Int) -> String { list.atIndex(i)?.stringValue ?? "" }
    func number(_ i: Int) -> Double { list.atIndex(i)?.doubleValue ?? 0 }
    let title = text(1).trimmingCharacters(in: .whitespaces)
    if title.isEmpty { return nil }
    let state = text(6)
    if state == "stopped" { return nil }
    return State(
      bundleId: player.bundleId,
      title: title,
      artist: text(2),
      album: text(3),
      durationMs: Int(number(4)),
      positionMs: Int(number(5) * 1000),
      isPlaying: state == "playing",
      artworkUrl: isSpotify ? list.atIndex(7)?.stringValue : nil,
      nextTitle: isSpotify ? nil : list.atIndex(7)?.stringValue,
      nextArtist: isSpotify ? nil : list.atIndex(8)?.stringValue,
      nextDurationMs: isSpotify ? 0 : Int(number(9)),
      readAt: Date())
  }

  /// ¿Faltan menos de 2 segundos (o ya se pasó) para que termine?
  private func nearEnd() -> Bool {
    guard let s = lastEmitted, s.isPlaying, s.durationMs > 0 else { return false }
    return s.positionNow() >= s.durationMs - 2000
  }

  private func pollNow(force: Bool) {
    let states = Self.players.compactMap(read)
    lastStates = states
    if let playing = states.first(where: { $0.isPlaying }) { lastPlayingBundle = playing.bundleId }

    let chosen =
      states.first(where: { $0.bundleId == preferred })
      ?? states.first(where: { $0.isPlaying && $0.bundleId == lastEmitted?.bundleId })
      ?? states.first(where: { $0.isPlaying })
      ?? states.first(where: { $0.bundleId == lastPlayingBundle })
      ?? states.first

    guard let s = chosen else {
      if lastEmitted != nil || force {
        lastEmitted = nil
        DispatchQueue.main.async {
          self.current = nil
          self.sink?(nil)
        }
      }
      return
    }

    if !force, let prev = lastEmitted, prev.key == s.key, prev.isPlaying == s.isPlaying,
       abs(prev.positionNow() - s.positionMs) < 1500 {
      return
    }
    emit(s)
  }

  private func emit(_ s: State) {
    lastEmitted = s
    var map: [String: Any] = [
      "title": s.title,
      "artist": s.artist,
      "album": s.album,
      "durationMs": s.durationMs,
      "positionMs": s.positionMs,
      "isPlaying": s.isPlaying,
      "playbackSpeed": 1.0,
      "packageName": s.bundleId,
      "nextTitle": s.nextTitle ?? "",
      "nextArtist": s.nextArtist ?? "",
      "nextDurationMs": s.nextDurationMs,
      "players": lastStates.map {
        ["packageName": $0.bundleId, "title": $0.title, "artist": $0.artist, "isPlaying": $0.isPlaying]
      },
    ]
    if artwork?.key == s.key, let data = artwork?.data {
      map["albumArt"] = FlutterStandardTypedData(bytes: data)
    }
    let readAt = s.readAt
    DispatchQueue.main.async {
      self.current = (s.title, s.artist, s.positionMs, s.isPlaying, readAt)
      self.sink?(map)
    }
    // Después de avisar la canción (sin esperar la carátula).
    if artwork?.key != s.key { loadArtwork(for: s) }
  }

  /// La carátula se busca una vez por canción, en otra cola, y cuando
  /// llega se vuelve a mandar el estado con ella. Se achica a 600 px: Música
  /// la entrega en tamaño original (a veces varios MB) y mandarla entera en
  /// cada actualización hacía todo más lento.
  private func loadArtwork(for s: State) {
    guard artworkLoading != s.key else { return }
    artworkLoading = s.key
    let done: (Data?) -> Void = { data in
      let small = data.flatMap(Self.shrink)
      self.queue.async {
        self.artworkLoading = nil
        self.artwork = (s.key, small)
        if self.lastEmitted?.key == s.key { self.pollNow(force: true) }
      }
    }
    if s.bundleId == "com.apple.Music" {
      // En la misma cola que el resto (AppleScript no aguanta dos pedidos a
      // la vez), pero en la vuelta siguiente: el aviso de la canción ya salió.
      queue.async { done(self.run(Self.musicArtworkScript)?.data) }
    } else if let raw = s.artworkUrl, let url = URL(string: raw), url.scheme == "https" {
      URLSession.shared.dataTask(with: url) { data, response, _ in
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        done(ok ? data : nil)
      }.resume()
    } else {
      done(nil)
    }
  }

  /// JPEG de 600 px como máximo.
  private static func shrink(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 600,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
  }
}
