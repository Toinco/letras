import 'dart:async';
import 'dart:typed_data';

import '../models/song.dart';
import 'artwork_service.dart';
import 'lyrics_finder.dart';
import 'lyrics_storage_service.dart';
import 'settings_service.dart';
import 'spotify_auth_service.dart';
import 'spotify_service.dart';
import 'translation_service.dart';

/// Resultado de una pasada de sincronización con "me gusta" de Spotify.
class FavoritesSyncResult {
  final int total;
  final int downloaded;
  final int skipped;
  final int removedStale;
  final String? error;

  const FavoritesSyncResult({
    required this.total,
    required this.downloaded,
    required this.skipped,
    required this.removedStale,
    this.error,
  });
}

/// Progreso de una sincronización en curso, para que cualquier pantalla
/// pueda mostrarlo (no solo la que la arrancó).
class FavoritesSyncProgress {
  final int done;
  final int total;
  final int skipped;
  final int downloaded;

  const FavoritesSyncProgress({
    required this.done,
    required this.total,
    required this.skipped,
    required this.downloaded,
  });
}

/// Sincroniza la biblioteca de "me gusta" de Spotify con las letras
/// descargadas, sin depender de ninguna pantalla: se puede llamar apenas
/// arranca la app (para que ande "en segundo plano" mientras la app está
/// abierta, sin necesidad de entrar a la sección de Favoritos), o desde la
/// propia pantalla de Favoritos para el botón "Descargar todas".
///
/// Descarga lo que falte, borra lo que se sacó de "me gusta" (solo lo que
/// se había bajado por venir de ahí), y nunca hace dos pasadas a la vez.
class FavoritesSyncService {
  static final FavoritesSyncService _instance = FavoritesSyncService._();
  factory FavoritesSyncService() => _instance;
  FavoritesSyncService._();

  final _spotifyAuth = SpotifyAuthService();
  final _spotifyService = SpotifyService();
  final _storage = LyricsStorageService();
  final _translationService = TranslationService();
  final _artworkService = ArtworkService();
  final _settingsService = SettingsService();

  bool _running = false;
  bool get isRunning => _running;

  bool _cancelRequested = false;

  Future<FavoritesSyncResult>? _inFlight;

  final _progressController = StreamController<FavoritesSyncProgress>.broadcast();

  /// Progreso de la sincronización que esté corriendo en este momento
  /// (la haya arrancado quien la haya arrancado). Cualquier pantalla puede
  /// escucharlo para mostrar una barra de progreso real, incluso si la
  /// sincronización arrancó sola al abrir la app.
  Stream<FavoritesSyncProgress> get progressStream => _progressController.stream;

  /// Corta la sincronización en curso, la haya arrancado quien la haya
  /// arrancado (por ejemplo, desde el botón "Cancelar" de cualquier
  /// pantalla que esté mostrando el progreso).
  void requestCancel() => _cancelRequested = true;

  /// Si Spotify está conectado y la descarga automática está prendida en
  /// Ajustes, sincroniza. Si no, no hace nada (devuelve `null`). Pensado
  /// para llamarse solo, sin pantalla de por medio (por ejemplo, apenas
  /// abre la app).
  Future<FavoritesSyncResult?> syncIfEnabled() async {
    if (_running) return null;
    final connected = await _spotifyAuth.isConnected();
    if (!connected) return null;
    final enabled = await _settingsService.getAutoDownloadFavorites();
    if (!enabled) return null;
    return sync();
  }

  /// Sincroniza ahora mismo (se usa también desde "Descargar todas", con o
  /// sin el toggle de auto-descarga prendido). [onProgress] recibe
  /// (hechas, total, saltadas, nuevas) para poder mostrar una barra de
  /// progreso; [isCancelled] permite cortar a mitad de camino.
  ///
  /// Si ya hay una sincronización corriendo (por ejemplo, la que arranca
  /// sola al abrir la app), NO arranca una segunda en paralelo: se
  /// "engancha" a la que ya está en curso y devuelve su resultado final,
  /// re-emitiendo su progreso a través de [onProgress]. Así, tocar
  /// "Descargar todas" mientras ya se está sincronizando en segundo plano
  /// siempre muestra progreso real en vez de no hacer nada.
  Future<FavoritesSyncResult> sync({
    List<Song>? knownFirstPage,
    String? knownNextUrl,
    void Function(int done, int total, int skipped, int downloaded)? onProgress,
    bool Function()? isCancelled,
  }) {
    if (_running && _inFlight != null) {
      if (onProgress != null) {
        final sub = _progressController.stream.listen(
          (p) => onProgress(p.done, p.total, p.skipped, p.downloaded),
        );
        _inFlight!.whenComplete(sub.cancel);
      }
      return _inFlight!;
    }

    final future = _runSync(
      knownFirstPage: knownFirstPage,
      knownNextUrl: knownNextUrl,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    _inFlight = future;
    future.whenComplete(() => _inFlight = null);
    return future;
  }

  Future<FavoritesSyncResult> _runSync({
    List<Song>? knownFirstPage,
    String? knownNextUrl,
    void Function(int done, int total, int skipped, int downloaded)? onProgress,
    bool Function()? isCancelled,
  }) async {
    _running = true;
    _cancelRequested = false;
    try {
      final externalCancelled = isCancelled ?? () => false;
      bool cancelled() => _cancelRequested || externalCancelled();
      final allSongs = List<Song>.from(knownFirstPage ?? const []);
      var nextUrl = knownNextUrl;
      var reportedTotal = allSongs.length;

      if (knownFirstPage == null) {
        // No nos pasaron una primera página ya cargada: la pedimos.
        final page = await _spotifyService.getLikedSongs();
        allSongs.addAll(page.songs);
        nextUrl = page.nextUrl;
        reportedTotal = page.total;
      }

      while (nextUrl != null && !cancelled()) {
        final page = await _spotifyService.getLikedSongs(pageUrl: nextUrl);
        allSongs.addAll(page.songs);
        nextUrl = page.nextUrl;
      }

      // Solo borramos lo que ya no está en "me gusta" si de verdad
      // recorrimos toda la biblioteca (si no, es más seguro no borrar
      // nada a arriesgarnos a borrar algo que sigues teniendo).
      final paginationComplete = !cancelled() && allSongs.length >= reportedTotal;
      final removedStale = paginationComplete ? await _removeStaleDownloads(allSongs) : 0;

      var downloaded = 0;
      var skipped = 0;
      var nextIndex = 0;

      // Antes esto bajaba una canción por vez, con una pausa fija de
      // 200ms entre cada una — segura para no saturar LRCLIB, pero muy
      // lenta con bibliotecas grandes (varios minutos). Ahora corren
      // varias descargas en paralelo (hasta 4 a la vez): mucho más rápido
      // sin dejar de ser prudentes con la API gratuita.
      Future<void> worker() async {
        while (true) {
          if (cancelled()) return;
          final i = nextIndex;
          if (i >= allSongs.length) return;
          nextIndex++;
          final song = allSongs[i];

          // Chequeo local, sin red: si ya está descargada, la saltamos.
          final alreadySaved = await _storage.isSaved(song.title, song.artist);
          if (alreadySaved) {
            await _storage.markSpotifyLinked(song.title, song.artist);
            skipped++;
          } else {
            final ok = await _downloadOne(song);
            if (ok) downloaded++;
          }
          onProgress?.call(downloaded + skipped, allSongs.length, skipped, downloaded);
          _progressController.add(FavoritesSyncProgress(
            done: downloaded + skipped,
            total: allSongs.length,
            skipped: skipped,
            downloaded: downloaded,
          ));
        }
      }

      if (allSongs.isNotEmpty) {
        final workerCount = allSongs.length < 4 ? allSongs.length : 4;
        await Future.wait(List.generate(workerCount, (_) => worker()));
      }

      return FavoritesSyncResult(
        total: allSongs.length,
        downloaded: downloaded,
        skipped: skipped,
        removedStale: removedStale,
      );
    } catch (e) {
      return FavoritesSyncResult(total: 0, downloaded: 0, skipped: 0, removedStale: 0, error: '$e');
    } finally {
      _running = false;
    }
  }

  Future<bool> _downloadOne(Song song) async {
    try {
      final result = await LyricsFinder().find(song.title, song.artist, durationSeconds: song.durationSeconds);
      if (result == null) return false;

      // Traducción y carátula, en paralelo (antes se esperaba una y
      // después la otra).
      final fetches = await Future.wait<dynamic>([
        result.hasSyncedLyrics
            ? _translationService.translate(
                result.syncedLyrics.map((l) => l.text).toList(),
              )
            : Future.value(null),
        _artworkService.fetchArtworkBytes(song.title, song.artist,
            knownUrl: song.artworkUrl, album: song.album, durationSeconds: song.durationSeconds),
      ]);
      final translated = fetches[0] as List<String>?;
      final artwork = fetches[1] as Uint8List?;
      await _storage.save(
        result.copyWith(translatedLines: translated, translationLang: SettingsService.translationLang.value, song: result.song.withIdentityFrom(song)),
        artworkBytes: artwork,
      );
      await _storage.markSpotifyLinked(song.title, song.artist);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> _removeStaleDownloads(List<Song> currentLikes) async {
    String keyOf(String artist, String title) =>
        '${artist.toLowerCase().trim()}|||${title.toLowerCase().trim()}';

    final likedKeys = currentLikes.map((s) => keyOf(s.artist, s.title)).toSet();
    final linked = await _storage.getSpotifyLinkedSongs();

    var removedCount = 0;
    for (final entry in linked) {
      if (!likedKeys.contains(keyOf(entry.artist, entry.title))) {
        await _storage.remove(entry.title, entry.artist);
        removedCount++;
      }
    }
    return removedCount;
  }
}
