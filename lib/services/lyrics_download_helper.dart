import 'dart:typed_data';

import '../models/song.dart';
import 'artwork_service.dart';
import 'lyrics_finder.dart';
import 'lyrics_storage_service.dart';
import 'settings_service.dart';
import 'translation_service.dart';

/// Resultado de intentar descargar la letra de una sola canción.
class DownloadOutcome {
  final Song song;
  final bool success;
  final bool alreadyHad;

  const DownloadOutcome({required this.song, required this.success, required this.alreadyHad});
}

/// Descarga la letra (+ traducción + carátula) de una o varias canciones,
/// salteando las que ya estaban descargadas. Se comparte entre Favoritos,
/// Álbumes y la selección múltiple del buscador para no repetir en cada
/// pantalla la misma lógica de "buscar en LRCLIB, traducir, bajar
/// carátula y guardar".
class LyricsDownloadHelper {
  final _storage = LyricsStorageService();
  final _translationService = TranslationService();
  final _artworkService = ArtworkService();

  Future<DownloadOutcome> downloadOne(Song song, {bool markSpotifyLinked = false}) async {
    try {
      if (await _storage.isSaved(song.title, song.artist)) {
        if (markSpotifyLinked) await _storage.markSpotifyLinked(song.title, song.artist);
        return DownloadOutcome(song: song, success: true, alreadyHad: true);
      }

      final result = await LyricsFinder().find(song.title, song.artist, durationSeconds: song.durationSeconds);
      if (result == null) {
        return DownloadOutcome(song: song, success: false, alreadyHad: false);
      }

      // Traducción y carátula se piden a la vez: antes se esperaba una y
      // después la otra, el doble de lento para cada canción.
      final fetches = await Future.wait<dynamic>([
        result.hasSyncedLyrics
            ? _translationService.translate(
                result.syncedLyrics.map((l) => l.text).toList(),
              )
            : Future.value(null),
        _artworkService.fetchArtworkBytes(song.title, song.artist, knownUrl: song.artworkUrl),
      ]);
      final translated = fetches[0] as List<String>?;
      final artwork = fetches[1] as Uint8List?;

      await _storage.save(
        result.copyWith(translatedLines: translated, translationLang: SettingsService.translationLang.value, song: result.song.withIdentityFrom(song)),
        artworkBytes: artwork,
      );
      if (markSpotifyLinked) await _storage.markSpotifyLinked(song.title, song.artist);
      return DownloadOutcome(song: song, success: true, alreadyHad: false);
    } catch (_) {
      return DownloadOutcome(song: song, success: false, alreadyHad: false);
    }
  }

  /// Descarga varias canciones con concurrencia acotada (varias en
  /// paralelo, no una por una con espera entre cada una): mucho más
  /// rápido para descargas masivas (favoritos de Spotify, un álbum
  /// entero, selección múltiple), sin saturar de golpe la red ni las
  /// APIs gratuitas de por medio.
  Future<List<DownloadOutcome>> downloadMany(
    List<Song> songs, {
    int concurrency = 4,
    bool markSpotifyLinked = false,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (songs.isEmpty) return [];
    final results = List<DownloadOutcome?>.filled(songs.length, null);
    var nextIndex = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final i = nextIndex;
        if (i >= songs.length) return;
        nextIndex++;
        final outcome = await downloadOne(songs[i], markSpotifyLinked: markSpotifyLinked);
        results[i] = outcome;
        done++;
        onProgress?.call(done, songs.length);
      }
    }

    final workerCount = concurrency.clamp(1, songs.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.whereType<DownloadOutcome>().toList();
  }
}
