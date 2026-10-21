import 'package:shared_preferences/shared_preferences.dart';

import 'error_log.dart';
import 'lyrics_download_helper.dart';
import 'spotify_auth_service.dart';
import 'spotify_service.dart';

/// Descarga automática de playlists enteras de Spotify (no solo los "me
/// gusta"): las playlists marcadas se revisan al abrir la app y se bajan
/// las letras de las canciones nuevas. Nunca borra nada (una canción que
/// se saca de una playlist puede seguir en otra).
class SpotifyPlaylistSync {
  static const _autoKey = 'spotify_auto_playlists';
  static bool _running = false;

  Future<Set<String>> autoPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_autoKey) ?? []).toSet();
  }

  Future<void> setAuto(String playlistId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_autoKey) ?? []).toSet();
    enabled ? set.add(playlistId) : set.remove(playlistId);
    await prefs.setStringList(_autoKey, set.toList());
  }

  /// Revisa las playlists marcadas y baja lo que falte. Devuelve cuántas
  /// letras nuevas se bajaron.
  Future<int> syncAuto() async {
    if (_running) return 0;
    final ids = await autoPlaylists();
    if (ids.isEmpty || !await SpotifyAuthService().isConnected()) return 0;
    _running = true;
    var added = 0;
    try {
      final spotify = SpotifyService();
      final helper = LyricsDownloadHelper();
      for (final id in ids) {
        final songs = await spotify.getPlaylistSongs(id);
        final outcomes = await helper.downloadMany(songs, concurrency: 3);
        added += outcomes.where((o) => o.success && !o.alreadyHad).length;
      }
    } catch (e, st) {
      ErrorLog.record('spotify playlists', e, st);
    } finally {
      _running = false;
    }
    return added;
  }
}
