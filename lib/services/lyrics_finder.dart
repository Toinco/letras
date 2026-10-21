import 'dart:async';
import 'dart:io';

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

  Future<({LyricsResult? result, bool transient})> _find(
      String title, String artist, int? durationSeconds) async {
    Object? networkError;
    LyricsResult? lrclib;
    try {
      lrclib = await _lrclib.getBestMatch(
        trackName: title,
        artistName: artist,
        durationSeconds: durationSeconds,
      );
    } catch (e) {
      if (_isNetwork(e)) networkError = e;
    }
    if (lrclib != null && (lrclib.hasSyncedLyrics || lrclib.instrumental)) {
      return (result: lrclib, transient: false);
    }

    if (SettingsService.extraSources.value) {
      try {
        final ne = await _netease.find(title, artist, durationSeconds: durationSeconds);
        if (ne != null) return (result: ne, transient: false);
      } catch (e, st) {
        if (_isNetwork(e)) networkError ??= e;
        ErrorLog.record('netease', e, st);
      }
    }
    if (lrclib != null) return (result: lrclib, transient: networkError != null);

    if (SettingsService.extraSources.value) {
      try {
        final g = await _genius.find(title, artist);
        if (g != null) return (result: g, transient: networkError != null);
      } catch (e, st) {
        if (_isNetwork(e)) networkError ??= e;
        ErrorLog.record('genius', e, st);
      }
    }
    // Sin conexión en todas: que se vea el error de red.
    if (networkError != null) throw networkError;
    return (result: null, transient: false);
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
