import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../services/accent_controller.dart';
import '../services/artwork_service.dart';
import '../services/audio_recognition_service.dart';
import '../services/history_service.dart';
import '../services/lyrics_finder.dart';
import '../services/lyrics_storage_service.dart';
import '../services/now_playing_service.dart';
import '../services/settings_service.dart';
import '../services/stats_service.dart';
import '../services/translation_service.dart';
import '../utils/platform.dart';

/// Resultado de reconocer una canción con el micrófono (una sola vez).
class MicRecognition {
  final Song song;
  final LyricsResult? lyrics;

  const MicRecognition(this.song, this.lyrics);
}

/// Todo el estado de "Reproduciendo", separado de la pantalla:
///
/// - qué suena (sesión multimedia del teléfono, o el micrófono en modo
///   continuo) y su posición,
/// - la letra (buscada en todas las fuentes, o la descargada),
/// - traducción y pronunciación,
/// - desfase por canción y por app,
/// - la letra fuera de la app (notificación / widget / burbuja),
/// - la búsqueda anticipada de la próxima canción de la cola,
/// - las estadísticas de escucha.
///
/// Vive mientras viva la app (lo crea Riverpod), así que sigue andando
/// aunque la pantalla no esté visible.
class NowPlayingController extends ChangeNotifier with WidgetsBindingObserver {
  final NowPlayingService nowPlaying;
  final LyricsFinder finder;
  final LyricsStorageService storage;
  final TranslationService translation;
  final ArtworkService artwork;
  final HistoryService history;
  final SettingsService settings;
  final AudioRecognitionService recognition;
  final StatsService stats;

  NowPlayingController({
    required this.nowPlaying,
    required this.finder,
    required this.storage,
    required this.translation,
    required this.artwork,
    required this.history,
    required this.settings,
    required this.recognition,
    required this.stats,
  });

  // ------------------------------------------------------------- estado

  bool checkingPermission = true;
  bool accessGranted = false;

  NowPlayingTrack? _sessionTrack;
  NowPlayingTrack? _micTrack;

  /// Lo que se está siguiendo: el micrófono si el modo continuo está
  /// prendido y reconoció algo, si no la app de música.
  NowPlayingTrack? get track => (continuousMic && _micTrack != null) ? _micTrack : _sessionTrack;

  LyricsResult? lyrics;
  bool loadingLyrics = false;
  String? lyricsError;
  bool saved = false;
  bool saving = false;

  /// Desfase guardado para la canción actual.
  Duration songOffset = Duration.zero;

  /// Desfase total: el de la canción + el general de la app que suena.
  Duration get offset => songOffset + SettingsService.appOffsetFor(track?.packageName);

  Duration get appOffset => SettingsService.appOffsetFor(track?.packageName);

  bool showTranslation = false;
  List<String>? translatedLines;
  List<String>? romanizedLines;
  bool translating = false;

  bool recognizing = false;
  bool continuousMic = false;

  /// Lo pone la pantalla: si la letra se está viendo ahora (para las
  /// estadísticas de "horas de letras vistas").
  bool lyricsVisible = false;

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get position => _positionController.stream;

  final StreamController<String> _messages = StreamController<String>.broadcast();

  /// Avisos para mostrar como SnackBar.
  Stream<String> get messages => _messages.stream;

  StreamSubscription<NowPlayingTrack?>? _trackSub;
  Timer? _clockTimer;
  Timer? _resyncTimer;
  Timer? _statsTimer;
  Timer? _lyricsDebounce;
  int _fetchToken = 0;
  int? _playId;
  String? _prefetchedFor;
  bool _subscribed = false;
  bool _disposed = false;

  // ------------------------------------------------------------- arranque

  void start() {
    WidgetsBinding.instance.addObserver(this);
    // Emite siempre (también en pausa): así una letra que recién termina
    // de cargar se ubica en la línea correcta en vez de quedar al principio.
    _clockTimer = Timer.periodic(const Duration(milliseconds: 150), (_) => _emitPosition());
    // Cada tanto le pedimos al lado nativo la posición real, para que la
    // letra no se vaya corriendo con el tiempo (el reloj interpolado deriva).
    _resyncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      final t = _sessionTrack;
      if (t != null && t.isPlaying && !(continuousMic && _micTrack != null)) nowPlaying.refresh();
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final id = _playId;
      if (id != null && lyricsVisible && (track?.isPlaying ?? false) && lyrics != null) {
        stats.addLyricsTime(id, 5);
      }
    });

    SettingsService.liveNotification.addListener(_pushLiveOptions);
    SettingsService.floatingBubble.addListener(_pushLiveOptions);
    SettingsService.appOffsets.addListener(_onOffsetChanged);
    SettingsService.preferredPackage.addListener(_onPreferredPackageChanged);
    SettingsService.translationLang.addListener(_onTranslationSettingsChanged);
    SettingsService.aiTranslation.addListener(_onTranslationSettingsChanged);
    SettingsService.showRomanization.addListener(_onRomanizationChanged);

    nowPlaying.setPreferredPackage(SettingsService.preferredPackage.value);
    _pushLiveOptions();
    checkPermission();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    SettingsService.liveNotification.removeListener(_pushLiveOptions);
    SettingsService.floatingBubble.removeListener(_pushLiveOptions);
    SettingsService.appOffsets.removeListener(_onOffsetChanged);
    SettingsService.preferredPackage.removeListener(_onPreferredPackageChanged);
    SettingsService.translationLang.removeListener(_onTranslationSettingsChanged);
    SettingsService.aiTranslation.removeListener(_onTranslationSettingsChanged);
    SettingsService.showRomanization.removeListener(_onRomanizationChanged);
    _trackSub?.cancel();
    _clockTimer?.cancel();
    _resyncTimer?.cancel();
    _statsTimer?.cancel();
    _lyricsDebounce?.cancel();
    _micSleep?.complete();
    _positionController.close();
    _messages.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _message(String text) {
    if (!_messages.isClosed) _messages.add(text);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!accessGranted) checkPermission();
    // La notificación o la burbuja se pueden apagar desde afuera de la
    // app ("Ocultar", la ×): releemos esas opciones.
    // Y volvemos a mandar las opciones: puede que se haya dado recién el
    // permiso de superposición para la burbuja.
    SettingsService.reloadOutsideOptions().then((_) => _pushLiveOptions());
  }

  Future<void> checkPermission() async {
    final granted = await nowPlaying.isNotificationAccessGranted();
    if (_disposed) return;
    accessGranted = granted;
    checkingPermission = false;
    _notify();
    if (granted && !_subscribed) _subscribe();
  }

  Future<void> openNotificationAccessSettings() => nowPlaying.openNotificationAccessSettings();

  void _subscribe() {
    _subscribed = true;
    _trackSub = nowPlaying.trackStream.listen((t) {
      final previous = track;
      _sessionTrack = t;
      _onTrackChanged(previous);
      _maybePrefetchNext(t);
    });
  }

  void _emitPosition() {
    final t = track;
    if (t != null && !_positionController.isClosed) {
      _positionController.add(t.estimatedPositionNow());
    }
  }

  void _onTrackChanged(NowPlayingTrack? previous) {
    final t = track;
    _notify();
    AccentController.updateFromArtwork(t?.albumArt);
    // Emitimos la posición en cada evento (no solo con el reloj), así un
    // seek o una pausa se reflejan al instante en la letra.
    _emitPosition();
    final isNewSong = !(t?.sameSongAs(previous) ?? previous == null);
    if (t != null && isNewSong) {
      // Algunas apps de música mandan los metadatos en varias tandas
      // apenas arranca una canción (por ejemplo, el título llega antes
      // que el artista). Esperamos un toque y, si la canción detectada
      // sigue siendo la misma, recién ahí buscamos.
      _lyricsDebounce?.cancel();
      final title = t.title;
      final artist = t.artist;
      // En la Mac los datos llegan completos de una vez: casi no hace falta esperar.
      _lyricsDebounce = Timer(Duration(milliseconds: isMac ? 80 : 350), () {
        final now = track;
        if (_disposed || now == null) return;
        if (now.title == title && now.artist == artist) {
          _fetchLyricsFor(now);
          history.add(now.toSong());
        }
      });
    } else if (t == null) {
      _lyricsDebounce?.cancel();
      lyrics = null;
      lyricsError = null;
      _playId = null;
      nowPlaying.clearLiveLyrics();
      _notify();
    }
  }

  // ------------------------------------------------------------- letra

  Future<void> _fetchLyricsFor(NowPlayingTrack t) async {
    // Token de esta búsqueda puntual: si mientras esperamos la respuesta
    // se pide otra canción, la respuesta de esta (más vieja) se descarta.
    final token = ++_fetchToken;
    final durationSeconds = t.duration.inSeconds > 0 ? t.duration.inSeconds : null;
    loadingLyrics = !LyricsFinder.isCached(t.title, t.artist, durationSeconds);
    lyricsError = null;
    lyrics = null;
    saved = false;
    translatedLines = null;
    romanizedLines = null;
    _notify();
    settings.getSyncOffset(t.title, t.artist).then((o) {
      if (!_disposed && token == _fetchToken) {
        songOffset = o;
        _notify();
        _pushLiveLyrics();
      }
    });
    stats.startPlay(t.title, t.artist).then((id) {
      if (token == _fetchToken) _playId = id;
    });
    // Si las fuentes están lentas (LRCLIB saturado), no dejamos la ruedita
    // girando: a los 12 s se ofrece reintentar. Si la letra llega después,
    // igual aparece sola.
    Timer(const Duration(seconds: 12), () {
      if (_disposed || token != _fetchToken || !loadingLyrics) return;
      loadingLyrics = false;
      lyricsError = 'La letra está tardando más de lo normal (los servidores de letras '
          'andan lentos). Puedes reintentar o esperar un poco más.';
      _notify();
    });
    try {
      // Si ya la habíamos descargado, la usamos directamente: es
      // instantáneo, funciona sin conexión y ya trae la traducción.
      var result = await storage.getSaved(t.title, t.artist);
      final wasSaved = result != null;
      result ??= await finder.find(t.title, t.artist, durationSeconds: durationSeconds);
      if (_disposed || token != _fetchToken) return;
      lyrics = result;
      loadingLyrics = false;
      saved = wasSaved;
      final lang = SettingsService.translationLang.value;
      translatedLines = result?.translationLang == lang ? result?.translatedLines : null;
      romanizedLines = result?.romanizedLines;
      lyricsError = result == null ? 'No encontramos la letra de esta canción.' : null;
      _notify();
      _pushLiveLyrics();
      _maybePrefetchNext(track);
      if (showTranslation && translatedLines == null) fetchTranslation();
      _maybeRomanize();
      if (result != null && !wasSaved && await settings.getAutoSaveListened()) {
        download(silent: true);
      }
    } catch (e) {
      if (_disposed || token != _fetchToken) return;
      loadingLyrics = false;
      lyricsError = e is SocketException || e is TimeoutException
          ? 'Sin conexión. Las letras que descargues se ven aunque no tengas internet.'
          : 'Error buscando la letra: $e';
      _notify();
      _pushLiveLyrics();
    }
  }

  void retry() {
    final t = track;
    if (t == null) return;
    LyricsFinder.forget(t.title, t.artist, t.duration.inSeconds > 0 ? t.duration.inSeconds : null);
    _fetchLyricsFor(t);
  }

  /// "¿Letra equivocada?": la elegida a mano se guarda para esta canción.
  Future<void> useChosenLyrics(LyricsResult chosen) async {
    lyrics = chosen;
    lyricsError = null;
    translatedLines = null;
    romanizedLines = null;
    saved = false;
    _notify();
    _pushLiveLyrics();
    if (showTranslation) fetchTranslation();
    _maybeRomanize();
    await download(silent: true);
    _message('Listo: se va a usar esta letra para esta canción.');
  }

  /// Reemplaza la letra por una editada/sincronizada a mano.
  Future<void> useEditedLyrics(LyricsResult edited) => useChosenLyrics(edited);

  // ------------------------------------------------------------- traducción

  void _onTranslationSettingsChanged() {
    translatedLines = null;
    _notify();
    if (showTranslation) fetchTranslation();
  }

  Future<List<String>?> _ensureTranslation() async {
    if (translatedLines != null) return translatedLines;
    final current = lyrics;
    if (current == null || !current.hasSyncedLyrics) return null;
    translating = true;
    _notify();
    try {
      final translated = await translation.translate(
        current.syncedLyrics.map((l) => l.text).toList(),
        title: current.song.title,
        artist: current.song.artist,
      );
      if (!_disposed && identical(current, lyrics)) translatedLines = translated;
      return translated;
    } finally {
      translating = false;
      _notify();
    }
  }

  Future<void> fetchTranslation() async {
    final translated = await _ensureTranslation();
    if (_disposed) return;
    if (translated == null) {
      _message('No se pudo traducir ahora. Prueba de nuevo en un rato.');
    } else if (translated.isEmpty) {
      _message('Esta letra ya está en el idioma elegido.');
    }
  }

  void toggleTranslation() {
    showTranslation = !showTranslation;
    _notify();
    if (showTranslation && translatedLines == null) fetchTranslation();
  }

  void _onRomanizationChanged() {
    _notify();
    _maybeRomanize();
  }

  Future<void> _maybeRomanize() async {
    final current = lyrics;
    if (current == null || romanizedLines != null || !SettingsService.showRomanization.value) return;
    if (!TranslationService.needsRomanization(current.displayLines)) return;
    final roman = await translation.romanize(current.displayLines);
    if (_disposed || !identical(current, lyrics)) return;
    romanizedLines = roman;
    _notify();
  }

  // ------------------------------------------------------------- descargar

  Future<void> download({bool silent = false}) async {
    final current = lyrics;
    if (current == null || saving) return;
    saving = true;
    _notify();
    try {
      // Bajamos también la traducción y la carátula para que quede todo
      // disponible sin conexión.
      final t = track;
      final translated = await _ensureTranslation();
      final art = t?.albumArt ??
          await artwork.fetchArtworkBytes(current.song.title, current.song.artist);
      var toSave = current.copyWith(
        translatedLines: translated,
        translationLang: translated == null ? null : SettingsService.translationLang.value,
        romanizedLines: romanizedLines,
      );
      // Guardamos con el título/artista que se detectó (no el que
      // devuelve la fuente, que puede venir levemente distinto).
      if (t != null) toSave = toSave.copyWith(song: current.song.withIdentityFrom(t.toSong()));
      await storage.save(toSave, artworkBytes: art);
      if (!_disposed && identical(current, lyrics)) {
        saved = true;
        if (!silent) _message('Letra descargada.');
      }
    } catch (e) {
      if (!silent) _message('No se pudo descargar: $e');
    } finally {
      saving = false;
      _notify();
    }
  }

  // ------------------------------------------------------------- reproducción

  void seekTo(Duration position) {
    if (track?.fromMicrophone ?? false) return;
    nowPlaying.seekTo(position);
    // Optimista: movemos la letra ya, sin esperar a que la app de música
    // confirme el salto.
    if (!_positionController.isClosed) _positionController.add(position);
  }

  void togglePlayPause() {
    final t = track;
    if (t == null || t.fromMicrophone) return;
    t.isPlaying ? nowPlaying.pause() : nowPlaying.play();
  }

  void skipNext() => nowPlaying.skipToNext();
  void skipPrevious() => nowPlaying.skipToPrevious();

  Future<void> setSongOffset(Duration value) async {
    final t = track;
    if (t == null) return;
    songOffset = value;
    _notify();
    _pushLiveOffset();
    await settings.setSyncOffset(t.title, t.artist, value);
  }

  /// Desfase general para todo lo que suena en la app actual (por ejemplo,
  /// auriculares Bluetooth con latencia).
  Future<void> setAppOffset(Duration value) async {
    final pkg = track?.packageName;
    if (pkg == null) return;
    await settings.setAppOffset(pkg, value);
  }

  void _onOffsetChanged() {
    _notify();
    _pushLiveOffset();
  }

  /// Elegir a mano qué app seguir cuando suenan dos a la vez.
  Future<void> choosePlayer(String? packageName) => settings.setPreferredPackage(packageName);

  void _onPreferredPackageChanged() {
    nowPlaying.setPreferredPackage(SettingsService.preferredPackage.value);
    _notify();
  }

  // ------------------------------------------------------------- letra fuera de la app

  Future<void> _pushLiveOptions() async {
    final bubble = SettingsService.floatingBubble.value && await nowPlaying.canDrawOverlays();
    await nowPlaying.setLiveOptions(
      notification: SettingsService.liveNotification.value,
      bubble: bubble,
    );
    _pushLiveLyrics();
  }

  void _pushLiveLyrics() {
    final t = track;
    if (t == null) {
      nowPlaying.clearLiveLyrics();
      return;
    }
    final current = lyrics;
    nowPlaying.setLiveLyrics(
      title: t.title,
      artist: t.artist,
      packageName: t.packageName,
      offsetMs: offset.inMilliseconds,
      lines: current == null || !current.hasSyncedLyrics
          ? const []
          : [
              for (final l in current.syncedLyrics)
                (ms: l.timestamp.inMilliseconds, text: l.text),
            ],
    );
  }

  void _pushLiveOffset() => nowPlaying.setLiveOffset(offset.inMilliseconds);

  // ------------------------------------------------------------- próxima de la cola

  /// Si la app de música dice cuál es la próxima canción, buscamos su
  /// letra ya (queda en caché), así aparece al instante cuando empiece.
  void _maybePrefetchNext(NowPlayingTrack? t) {
    if (!SettingsService.prefetchNext.value) return;
    // Primero la que suena: pedir las dos juntas hace que LRCLIB (cuando
    // está cargado) conteste "servidor saturado" a todo. Se vuelve a llamar
    // cuando llega la letra de la actual.
    if (loadingLyrics || (lyrics == null && lyricsError == null)) return;
    final title = t?.nextTitle;
    final artist = t?.nextArtist;
    if (title == null || title.isEmpty) return;
    final id = '$title|$artist';
    if (id == _prefetchedFor) return;
    _prefetchedFor = id;
    // Primero la descargada (si existe no hace falta buscar nada).
    storage.isSaved(title, artist ?? '').then((isSaved) {
      if (isSaved) return;
      // Con la duración (si la app la informa, como Música de la Mac) queda
      // en caché con la misma clave que se usa cuando empieza: aparece al
      // instante. Sin duración, al menos LRCLIB ya la tiene a mano.
      final seconds = t?.nextDuration?.inSeconds;
      finder
          .find(title, artist ?? '', durationSeconds: seconds != null && seconds > 0 ? seconds : null)
          .catchError((_) => null);
    });
  }

  // ------------------------------------------------------------- micrófono

  /// Reconoce una sola vez lo que suena (para abrir su letra).
  Future<MicRecognition?> recognizeOnce() async {
    final token = await settings.getAudDToken();
    if (token.trim().isEmpty) {
      _message('Antes carga tu API token de AudD en Ajustes.');
      return null;
    }
    recognizing = true;
    _notify();
    try {
      final song = await recognition.recognizeFromMicrophone(apiToken: token);
      if (song == null) {
        _message('No se pudo reconocer la canción.');
        return null;
      }
      history.add(song);
      final found = await storage.getSaved(song.title, song.artist) ?? await finder.findSong(song);
      if (found == null) {
        _message('Es "${song.title}" de ${song.artist}, pero no encontramos la letra.');
      }
      return MicRecognition(song, found);
    } catch (e) {
      _message('Error: $e');
      return null;
    } finally {
      recognizing = false;
      _notify();
    }
  }

  Completer<void>? _micSleep;

  /// Modo continuo: el micrófono va reconociendo canción tras canción (para
  /// música que suena en un altavoz, la radio, una fiesta...). Cada
  /// reconocimiento gasta una consulta de AudD.
  Future<void> toggleContinuousMic() async {
    if (continuousMic) {
      continuousMic = false;
      _micSleep?.complete();
      await recognition.cancel();
      final previous = track;
      _micTrack = null;
      _onTrackChanged(previous);
      return;
    }
    final token = await settings.getAudDToken();
    if (token.trim().isEmpty) {
      _message('Antes carga tu API token de AudD en Ajustes.');
      return;
    }
    continuousMic = true;
    _notify();
    _message('Escuchando con el micrófono. Va a ir detectando cada canción.');
    unawaited(_micLoop(token));
  }

  Future<void> _micLoop(String token) async {
    var failures = 0;
    while (continuousMic && !_disposed) {
      recognizing = true;
      _notify();
      MicMatch? match;
      try {
        match = await recognition.recognizeWithPosition(apiToken: token);
      } catch (e) {
        failures++;
        if (e.toString().contains('Permiso') || failures >= 3) {
          _message('Se cortó la escucha continua: $e');
          recognizing = false;
          if (continuousMic) await toggleContinuousMic();
          return;
        }
      }
      recognizing = false;
      if (!continuousMic) break;

      var wait = const Duration(seconds: 20);
      if (match != null) {
        failures = 0;
        await _setMicTrack(match);
        final total = match.song.durationSeconds;
        if (total != null && total > 0) {
          // Volvemos a escuchar poco después de que termine esta canción
          // (y como mucho en 90 s, por si alguien la cambió antes).
          final remaining = Duration(seconds: total) - match.positionNow();
          final secs = (remaining.inSeconds + 4).clamp(15, 90);
          wait = Duration(seconds: secs);
        } else {
          wait = const Duration(seconds: 45);
        }
      }
      _notify();
      _micSleep = Completer<void>();
      final timer = Timer(wait, () {
        if (!(_micSleep?.isCompleted ?? true)) _micSleep!.complete();
      });
      await _micSleep!.future;
      timer.cancel();
    }
    recognizing = false;
    _notify();
  }

  Future<void> _setMicTrack(MicMatch match) async {
    final song = match.song;
    final previous = track;
    final same = _micTrack != null && _micTrack!.title == song.title && _micTrack!.artist == song.artist;
    _micTrack = NowPlayingTrack(
      title: song.title,
      artist: song.artist,
      album: song.album,
      position: match.positionNow(),
      duration: Duration(seconds: song.durationSeconds ?? 0),
      isPlaying: true,
      capturedAt: DateTime.now(),
      albumArt: same ? _micTrack!.albumArt : null,
      packageName: NowPlayingTrack.micPackage,
    );
    _onTrackChanged(previous);
    if (!same) {
      final art = await storage.getArtworkBytes(song.title, song.artist) ??
          await artwork.fetchArtworkBytes(song.title, song.artist);
      if (art != null && _micTrack?.title == song.title) {
        _micTrack = _micTrack!.withAlbumArt(art);
        AccentController.updateFromArtwork(art);
        _notify();
      }
    }
  }
}
