import 'dart:convert';

import '../models/song.dart';
import 'spotify_auth_service.dart';
import 'app_http.dart';

/// Una página de resultados de "Canciones que te gustan" de Spotify.
class SpotifyLikedSongsPage {
  final List<Song> songs;
  final String? nextUrl;
  final int total;

  const SpotifyLikedSongsPage({
    required this.songs,
    required this.nextUrl,
    required this.total,
  });
}

/// Una playlist de Spotify del usuario.
class SpotifyPlaylist {
  final String id;
  final String name;
  final String? imageUrl;
  final int trackCount;
  final String owner;

  const SpotifyPlaylist({
    required this.id,
    required this.name,
    this.imageUrl,
    required this.trackCount,
    required this.owner,
  });
}

/// Cliente de la API web de Spotify para leer la biblioteca del usuario.
class SpotifyService {
  final SpotifyAuthService _auth = SpotifyAuthService();

  /// Trae una página de "Canciones que te gustan". Pasa [pageUrl] (el
  /// `next` de la página anterior) para pedir la siguiente tanda.
  Future<SpotifyLikedSongsPage> getLikedSongs({String? pageUrl, int limit = 50}) async {
    final token = await _auth.getValidAccessToken();
    final uri = pageUrl != null
        ? Uri.parse(pageUrl)
        : Uri.https('api.spotify.com', '/v1/me/tracks', {'limit': '$limit'});

    final response = await AppHttp.get(uri, headers: {'Authorization': 'Bearer $token'}, timeout: const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Spotify respondió ${response.statusCode}');
    }

    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items = json['items'] as List<dynamic>? ?? [];

    final songs = items.map((item) {
      final track = (item as Map<String, dynamic>)['track'] as Map<String, dynamic>? ?? {};
      return songFromTrack(track);
    }).toList();

    return SpotifyLikedSongsPage(
      songs: songs,
      nextUrl: json['next'] as String?,
      total: (json['total'] as num?)?.toInt() ?? songs.length,
    );
  }

  /// Arma una [Song] a partir del objeto "track" de la API de Spotify.
  static Song songFromTrack(Map<String, dynamic> track) {
    final artists = (track['artists'] as List<dynamic>?)
            ?.map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .join(', ') ??
        '';
    final album = track['album'] as Map<String, dynamic>?;
    final images = album?['images'] as List<dynamic>?;
    final artworkUrl =
        (images != null && images.isNotEmpty) ? images.first['url'] as String? : null;

    return Song(
      title: track['name'] as String? ?? '',
      artist: artists,
      album: album?['name'] as String?,
      durationSeconds: ((track['duration_ms'] as num?)?.toInt() ?? 0) ~/ 1000,
      artworkUrl: artworkUrl,
    );
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final token = await _auth.getValidAccessToken();
    final response = await AppHttp.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
      timeout: const Duration(seconds: 10),
      tag: 'spotify',
    );
    if (response.statusCode == 403) {
      throw Exception('Spotify no dio permiso para leer playlists. Reconecta tu cuenta en Ajustes.');
    }
    if (response.statusCode != 200) {
      throw Exception('Spotify respondió ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Todas las playlists del usuario (propias y las que sigue).
  Future<List<SpotifyPlaylist>> getPlaylists() async {
    final out = <SpotifyPlaylist>[];
    Uri? next = Uri.https('api.spotify.com', '/v1/me/playlists', {'limit': '50'});
    while (next != null) {
      final json = await _getJson(next);
      for (final p in (json['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
        final images = p['images'] as List<dynamic>?;
        // El total de canciones viene en "tracks" (o "items" en la API nueva).
        final tracks = (p['items'] ?? p['tracks']) as Map<String, dynamic>?;
        out.add(SpotifyPlaylist(
          id: p['id'] as String,
          name: p['name'] as String? ?? '',
          imageUrl: (images != null && images.isNotEmpty) ? images.first['url'] as String? : null,
          trackCount: (tracks?['total'] as num?)?.toInt() ?? 0,
          owner: (p['owner'] as Map<String, dynamic>?)?['display_name'] as String? ?? '',
        ));
      }
      final n = json['next'] as String?;
      next = n == null ? null : Uri.parse(n);
    }
    return out;
  }

  /// Las canciones de una playlist (sin episodios de podcasts ni locales).
  Future<List<Song>> getPlaylistSongs(String playlistId) async {
    final songs = <Song>[];
    // Spotify renombró "/tracks" a "/items" en 2026; probamos el nuevo y,
    // si no existe, el viejo.
    Uri? next = Uri.https('api.spotify.com', '/v1/playlists/$playlistId/items', {'limit': '100'});
    var triedLegacy = false;
    while (next != null) {
      Map<String, dynamic> json;
      try {
        json = await _getJson(next);
      } catch (e) {
        if (!triedLegacy && songs.isEmpty && e.toString().contains('404')) {
          triedLegacy = true;
          next = Uri.https('api.spotify.com', '/v1/playlists/$playlistId/tracks', {'limit': '100'});
          continue;
        }
        rethrow;
      }
      for (final item in (json['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
        final track = (item['item'] ?? item['track']) as Map<String, dynamic>?;
        if (track == null || track['type'] == 'episode' || track['is_local'] == true) continue;
        final song = songFromTrack(track);
        if (song.title.isNotEmpty) songs.add(song);
      }
      final n = json['next'] as String?;
      next = n == null ? null : Uri.parse(n);
    }
    return songs;
  }
}
