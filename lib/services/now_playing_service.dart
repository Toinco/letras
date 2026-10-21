import 'dart:async';

import 'package:flutter/services.dart';

import '../models/song.dart';

/// Foto de lo que está sonando ahora mismo en el teléfono (Spotify,
/// YouTube Music, etc.), obtenida vía el "Notification Listener" nativo
/// de Android. No incluye audio, solo metadatos + posición de reproducción.
class NowPlayingTrack {
  final String title;
  final String artist;
  final String? album;
  final Duration position; // posición dentro de la canción en el momento de [capturedAt]
  final Duration duration;
  final bool isPlaying;
  final DateTime capturedAt; // reloj del teléfono cuando se leyó [position]
  final Uint8List? albumArt; // carátula tal cual la expone la app de música, si está disponible
  final double playbackSpeed;

  /// Paquete de Android de la app que está sonando (ej. com.spotify.music).
  /// `mic` si la canción la reconoció el micrófono.
  final String? packageName;

  /// Próxima canción de la cola, si la app de música la expone.
  final String? nextTitle;
  final String? nextArtist;

  /// Todos los reproductores con algo cargado (para elegir cuál seguir
  /// cuando suenan dos a la vez).
  final List<PlayerInfo> players;

  const NowPlayingTrack({
    required this.title,
    required this.artist,
    this.album,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.capturedAt,
    this.albumArt,
    this.playbackSpeed = 1.0,
    this.packageName,
    this.nextTitle,
    this.nextArtist,
    this.players = const [],
  });

  static const micPackage = 'mic';

  bool get fromMicrophone => packageName == micPackage;

  static const _knownApps = {
    'com.spotify.music': 'Spotify',
    'com.google.android.apps.youtube.music': 'YouTube Music',
    'com.google.android.youtube': 'YouTube',
    'com.apple.android.music': 'Apple Music',
    'deezer.android.app': 'Deezer',
    'com.amazon.mp3': 'Amazon Music',
    'com.aspiro.tidal': 'TIDAL',
    'com.soundcloud.android': 'SoundCloud',
    'com.shazam.android': 'Shazam',
    'com.pandora.android': 'Pandora',
    'com.sec.android.app.music': 'Samsung Music',
    'com.miui.player': 'Mi Music',
    'app.revanced.android.apps.youtube.music': 'YouTube Music',
    // Mac
    'com.spotify.client': 'Spotify',
    'com.apple.Music': 'Música',
  };

  /// Nombre legible de la app que está sonando ("Spotify", "YouTube Music"...).
  String? get sourceAppName => appName(packageName);

  /// Nombre legible de una app por su paquete (o el paquete tal cual).
  static String? appName(String? pkg) {
    if (pkg == null || pkg.isEmpty) return null;
    if (pkg == micPackage) return 'el micrófono';
    return _knownApps[pkg];
  }

  /// Estima la posición actual interpolando el tiempo transcurrido desde
  /// que se capturó el dato. Así la animación de letras se ve fluida sin
  /// tener que consultar el canal nativo todo el tiempo.
  Duration estimatedPositionNow() {
    if (!isPlaying) return position;
    final elapsed = DateTime.now().difference(capturedAt);
    final estimated = position +
        Duration(microseconds: (elapsed.inMicroseconds * playbackSpeed).round());
    return estimated > duration && duration > Duration.zero
        ? duration
        : estimated;
  }

  /// Misma canción pero con [art] como carátula (para reutilizar la
  /// instancia anterior de bytes y que la imagen no parpadee).
  NowPlayingTrack withAlbumArt(Uint8List? art) => NowPlayingTrack(
        title: title,
        artist: artist,
        album: album,
        position: position,
        duration: duration,
        isPlaying: isPlaying,
        capturedAt: capturedAt,
        albumArt: art,
        playbackSpeed: playbackSpeed,
        packageName: packageName,
        nextTitle: nextTitle,
        nextArtist: nextArtist,
        players: players,
      );

  bool sameSongAs(NowPlayingTrack? other) {
    if (other == null) return false;
    return title == other.title && artist == other.artist;
  }

  Song toSong() => Song(
        title: title,
        artist: artist,
        album: album,
        durationSeconds: duration.inSeconds,
      );

  factory NowPlayingTrack.fromMap(Map<dynamic, dynamic> map) {
    final rawArt = map['albumArt'];
    return NowPlayingTrack(
      title: (map['title'] as String?)?.trim() ?? '',
      artist: (map['artist'] as String?)?.trim() ?? '',
      album: map['album'] as String?,
      position: Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
      isPlaying: map['isPlaying'] as bool? ?? false,
      capturedAt: DateTime.now(),
      albumArt: rawArt is Uint8List
          ? rawArt
          : (rawArt is List<int> ? Uint8List.fromList(rawArt) : null),
      playbackSpeed: (map['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
      packageName: map['packageName'] as String?,
      nextTitle: map['nextTitle'] as String?,
      nextArtist: map['nextArtist'] as String?,
      players: ((map['players'] as List<dynamic>?) ?? [])
          .map((p) => PlayerInfo.fromMap(Map<dynamic, dynamic>.from(p as Map)))
          .toList(),
    );
  }
}

/// Un reproductor con algo cargado (Spotify, YouTube Music...).
class PlayerInfo {
  final String packageName;
  final String title;
  final String artist;
  final bool isPlaying;

  const PlayerInfo({
    required this.packageName,
    required this.title,
    required this.artist,
    required this.isPlaying,
  });

  String get appName => NowPlayingTrack.appName(packageName) ?? packageName;

  factory PlayerInfo.fromMap(Map<dynamic, dynamic> m) => PlayerInfo(
        packageName: m['packageName'] as String? ?? '',
        title: m['title'] as String? ?? '',
        artist: m['artist'] as String? ?? '',
        isPlaying: m['isPlaying'] as bool? ?? false,
      );
}

/// Puente hacia el código nativo de Android (MainActivity.kt) que lee la
/// sesión multimedia activa (MediaSessionManager) a través del permiso de
/// "acceso a notificaciones". En la Mac responde NowPlayingBridge.swift,
/// que les pregunta a Spotify y a Música.
class NowPlayingService {
  static const _methodChannel = MethodChannel('io.letras.app/now_playing');
  static const _eventChannel = EventChannel('io.letras.app/now_playing_stream');

  Future<bool> isNotificationAccessGranted() async {
    try {
      final granted = await _methodChannel.invokeMethod<bool>('isNotificationAccessGranted');
      return granted ?? false;
    } catch (_) {
      // Sin canal nativo (tests) o la llamada falló.
      return false;
    }
  }

  /// Abre la pantalla de Ajustes de Android donde el usuario habilita el
  /// acceso a notificaciones para esta app (hay que hacerlo una sola vez).
  Future<void> openNotificationAccessSettings() => _invokeSafely('openNotificationAccessSettings');

  // --- Controles de transporte: le mandan el comando a la misma sesión
  // multimedia que ya usamos para detectar qué está sonando, así que
  // controlan de verdad la reproducción de Spotify/YouTube Music/etc. ---

  Future<void> play() async {
    try {
      await _methodChannel.invokeMethod('play');
    } on PlatformException {
      // Si falla (por ejemplo, la sesión ya no existe), no rompemos la UI.
    }
  }

  Future<void> pause() => _invokeSafely('pause');

  Future<void> skipToNext() => _invokeSafely('skipToNext');

  Future<void> skipToPrevious() => _invokeSafely('skipToPrevious');

  /// Pide al lado nativo que vuelva a emitir el estado actual con la
  /// posición recalculada, para corregir la deriva del reloj interpolado.
  Future<void> refresh() => _invokeSafely('refresh');

  Future<void> _invokeSafely(String method, [Object? arguments]) async {
    try {
      await _methodChannel.invokeMethod(method, arguments);
    } on PlatformException {
      // La sesión pudo haber desaparecido: no rompemos la UI por eso.
    } on MissingPluginException {
      // Sin canal nativo (tests o plataforma no soportada).
    }
  }

  /// Salta a [position] dentro de la canción (arrastrando la barra de
  /// progreso). No todas las apps de música soportan seekTo por igual,
  /// pero Spotify y YouTube Music sí.
  Future<void> seekTo(Duration position) =>
      _invokeSafely('seekTo', {'positionMs': position.inMilliseconds});

  /// Qué app seguir cuando suenan dos a la vez (null = automático).
  Future<void> setPreferredPackage(String? packageName) =>
      _invokeSafely('setPreferredPackage', {'packageName': packageName});

  // --- Letra fuera de la app: notificación, widget y burbuja (las dibuja
  // LiveLyricsService del lado nativo, que sigue la canción solo). ---

  Future<void> setLiveLyrics({
    required String title,
    required String artist,
    String? packageName,
    required List<({int ms, String text})> lines,
    required int offsetMs,
  }) =>
      _invokeSafely('setLiveLyrics', {
        'title': title,
        'artist': artist,
        'packageName': packageName,
        'offsetMs': offsetMs,
        'lines': [
          for (final l in lines) [l.ms, l.text],
        ],
      });

  Future<void> setLiveOffset(int offsetMs) => _invokeSafely('setLiveOffset', {'offsetMs': offsetMs});

  Future<void> clearLiveLyrics() => _invokeSafely('clearLiveLyrics');

  Future<void> setLiveOptions({required bool notification, required bool bubble}) =>
      _invokeSafely('setLiveOptions', {'notification': notification, 'bubble': bubble});

  Future<bool> canDrawOverlays() async {
    try {
      return await _methodChannel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openOverlaySettings() => _invokeSafely('openOverlaySettings');

  Future<bool> hasHomeWidgets() async {
    try {
      return await _methodChannel.invokeMethod<bool>('hasHomeWidgets') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stream con la canción detectada. Emite `null` cuando no hay ninguna
  /// sesión de música activa.
  Stream<NowPlayingTrack?> get trackStream {
    NowPlayingTrack? previous;
    return _eventChannel.receiveBroadcastStream().map((event) {
      if (event == null) return previous = null;
      final map = Map<dynamic, dynamic>.from(event as Map);
      if ((map['title'] as String?)?.trim().isEmpty ?? true) return previous = null;
      var track = NowPlayingTrack.fromMap(map);
      // Cada evento trae una copia nueva de la carátula: si es la misma
      // que antes, reusamos la instancia anterior para que Flutter no la
      // vuelva a decodificar (antes la miniatura parpadeaba en cada pausa,
      // seek o resincronización).
      final prevArt = previous?.albumArt;
      final art = track.albumArt;
      if (prevArt != null && art != null && track.sameSongAs(previous) && _sameBytes(prevArt, art)) {
        track = track.withAlbumArt(prevArt);
      }
      return previous = track;
    });
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    // Comparación rápida por muestreo (son JPEG de unos pocos KB).
    final step = (a.length ~/ 64).clamp(1, a.length);
    for (var i = 0; i < a.length; i += step) {
      if (a[i] != b[i]) return false;
    }
    return a.last == b.last;
  }
}
