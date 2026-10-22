import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../models/lyrics_result.dart';
import '../models/song.dart';
import 'error_log.dart';
import 'lrclib_service.dart';
import 'lyrics_sources.dart';
import 'settings_service.dart';

/// Busca la letra de una canción en todas las fuentes, en orden:
///
/// 1. LRCLIB (la principal: gratis, abierta, sincronizada).
/// 2. NetEase, si LRCLIB no la tiene sincronizada (mucho catálogo asiático,
///    y a veces con tiempos por palabra).
/// 3. La letra plana de LRCLIB, si había.
/// 4. Genius (letra plana) como último recurso.
///
/// Las fuentes 2 y 4 se pueden apagar en Ajustes.
class LyricsFinder {
  final LrclibService _lrclib;
  final NeteaseLyricsSource _netease;
  final GeniusLyricsSource _genius;

  LyricsFinder({
    LrclibService? lrclib,
    NeteaseLyricsSource? netease,
    GeniusLyricsSource? genius,
  })  : _lrclib = lrclib ?? LrclibService(),
        _netease = netease ?? NeteaseLyricsSource(),
        _genius = genius ?? GeniusLyricsSource();

  // Resultados ya resueltos (también los "no hay"), y búsquedas en curso:
  // si la misma canción se pide dos veces a la vez (por ejemplo, la
  // búsqueda anticipada de la próxima de la cola y la pantalla), se
  // comparte la misma búsqueda.
  static final Map<String, LyricsResult?> _cache = {};
  static final Map<String, Future<LyricsResult?>> _inFlight = {};

  static String _key(String title, String artist, int? duration) =>
      '${title.toLowerCase().trim()}|${artist.toLowerCase().trim()}|${duration ?? ''}';

  /// ¿Ya está resuelta (para no mostrar "cargando" si es instantánea)?
  static bool isCached(String title, String artist, int? durationSeconds) =>
      _cache.containsKey(_key(title, artist, durationSeconds));

  Future<LyricsResult?> find(String title, String artist, {int? durationSeconds}) {
    final key = _key(title, artist, durationSeconds);
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    return _inFlight[key] ??= _find(title, artist, durationSeconds).then((r) {
      // Si alguna fuente falló por red, no guardamos el resultado: puede
      // haber una mejor cuando vuelva la conexión.
      if (!r.transient) _cache[key] = r.result;
      return r.result;
    }).whenComplete(() {
      // Ojo: con `=> _inFlight.remove(key)` el callback devolvería este
      // mismo Future y whenComplete se quedaría esperándose a sí mismo.
      _inFlight.remove(key);
    });
  }

  Future<LyricsResult?> findSong(Song song) =>
      find(song.title, song.artist, durationSeconds: song.durationSeconds);

  static bool _isNetwork(Object e) =>
      e is SocketException || e is TimeoutException || e is HttpException;

  /// Cuánto se espera a LRCLIB antes de largar NetEase en paralelo.
  static Duration lrclibPatience = const Duration(milliseconds: 2500);

  Future<({LyricsResult? result, bool transient})> _find(
      String title, String artist, int? durationSeconds) async {
    Object? networkError;
    final extra = SettingsService.extraSources.value;

    // NetEase se pide como mucho una vez (puede arrancar antes, si LRCLIB
    // tarda, y después se reusa).
    Future<LyricsResult?>? neteaseFuture;
    Future<LyricsResult?> netease() => neteaseFuture ??= _netease
            .find(title, artist, durationSeconds: durationSeconds)
            .then<LyricsResult?>((r) => r, onError: (Object e, StackTrace st) {
          if (_isNetwork(e)) networkError ??= e;
          ErrorLog.record('netease', e, st);
          return null;
        });

    var lrclibDone = false;
    final lrclibFuture = _lrclib
        .getBestMatch(trackName: title, artistName: artist, durationSeconds: durationSeconds)
        .then<LyricsResult?>((r) => r, onError: (Object e) {
      if (_isNetwork(e)) networkError ??= e;
      return null;
    }).whenComplete(() => lrclibDone = true);

    LyricsResult? lrclib = await lrclibFuture.timeout(lrclibPatience, onTimeout: () => null);
    if (!lrclibDone && extra) {
      // LRCLIB anda lento (pasa cuando está saturado): probamos NetEase al
      // mismo tiempo y nos quedamos con la primera letra sincronizada.
      final first = await Future.any<(LyricsResult?, bool)>([
        lrclibFuture.then((r) => (r, true)),
        netease().then((r) => (r, false)),
      ]);
      if (first.$2) {
        lrclib = first.$1;
      } else if (first.$1?.hasSyncedLyrics ?? false) {
        return (result: first.$1, transient: false);
      } else {
        lrclib = await lrclibFuture;
      }
    } else if (!lrclibDone) {
      lrclib = await lrclibFuture;
    }
    if (lrclib != null && (lrclib.hasSyncedLyrics || lrclib.instrumental)) {
      if (extra && lrclib.hasSyncedLyrics && !lrclib.hasWordSync) {
        // LRCLIB casi nunca trae tiempos por palabra; NetEase muchas veces
        // sí (sobre todo en inglés). Con ellos el karaoke sigue al cantante
        // de verdad, con sus pausas, en vez de estimarse.
        final ne = await netease().timeout(wordSyncPatience, onTimeout: () => null);
        final aligned = ne == null ? null : alignWordSync(lrclib, ne);
        if (aligned != null) {
          return (result: aligned.copyWith(song: lrclib.song), transient: false);
        }
      }
      return (result: lrclib, transient: false);
    }

    if (extra) {
      final ne = await netease();
      if (ne != null) return (result: ne, transient: false);
    }
    if (lrclib != null) return (result: lrclib, transient: networkError != null);

    if (extra) {
      try {
        final g = await _genius.find(title, artist);
        if (g != null) return (result: g, transient: networkError != null);
      } catch (e, st) {
        if (_isNetwork(e)) networkError ??= e;
        ErrorLog.record('genius', e, st);
      }
    }
    // Sin conexión en todas: que se vea el error de red.
    final error = networkError;
    if (error != null) throw error;
    return (result: null, transient: false);
  }

  /// Cuánto se espera a NetEase para conseguir tiempos por palabra cuando
  /// LRCLIB ya dio la letra por línea.
  static Duration wordSyncPatience = const Duration(milliseconds: 2500);

  /// ¿[wordSynced] es la misma versión de la canción que [lineSynced]?
  static bool sameTiming(LyricsResult lineSynced, LyricsResult wordSynced) =>
      alignWordSync(lineSynced, wordSynced) != null;

  /// Devuelve [wordSynced] (tiempos por palabra) corrido para que coincida
  /// con los tiempos de [lineSynced] (LRCLIB, elegida por la duración de lo
  /// que suena), o `null` si no es la misma versión.
  ///
  /// Antes se aceptaba con que las líneas arrancaran a menos de 1,5 s, y se
  /// usaba tal cual: si la de NetEase venía corrida un segundo entero (otra
  /// edición del tema, un silencio distinto al principio), la letra quedaba
  /// atrasada todo el tema. Ahora se mide el corrimiento típico (mediana),
  /// se exige que casi todas las líneas coincidan después de corregirlo, y
  /// se corrige.
  static LyricsResult? alignWordSync(LyricsResult lineSynced, LyricsResult wordSynced) {
    if (!wordSynced.hasWordSync) return null;
    List<Duration> starts(LyricsResult r) => [
          for (final l in r.syncedLyrics)
            if (l.text.trim().isNotEmpty) l.timestamp,
        ];
    final a = starts(lineSynced);
    final b = starts(wordSynced);
    if (a.length < 3 || b.length < 3) return null;
    if ((a.length - b.length).abs() > math.max(4, a.length * 0.25)) return null;

    // Para cada línea de LRCLIB, la de NetEase que arranca más cerca.
    const window = Duration(milliseconds: 1500);
    final deltas = <int>[];
    var j = 0;
    for (final t in a) {
      while (j + 1 < b.length && b[j + 1] <= t) {
        j++;
      }
      Duration? best;
      for (final u in [b[j], if (j + 1 < b.length) b[j + 1]]) {
        final d = u - t;
        if (d.abs() <= window && (best == null || d.abs() < best.abs())) best = d;
      }
      if (best != null) deltas.add(best.inMilliseconds);
    }
    if (deltas.length < a.length * 0.7) return null;

    final sorted = [...deltas]..sort();
    final median = sorted[sorted.length ~/ 2];
    // Después de corregir el corrimiento, casi todas tienen que caer justas.
    const tolerance = 350;
    final tight = deltas.where((d) => (d - median).abs() <= tolerance).length;
    if (tight < a.length * 0.7) return null;

    if (median.abs() < 40) return wordSynced;
    final shift = Duration(milliseconds: -median);
    return wordSynced.copyWith(
      syncedLyrics: [for (final l in wordSynced.syncedLyrics) l.shifted(shift)],
    );
  }

  /// Olvida lo resuelto para esta canción (al elegir otra letra a mano).
  static void forget(String title, String artist, int? durationSeconds) =>
      _cache.remove(_key(title, artist, durationSeconds));

  /// Para tests.
  static void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }
}
