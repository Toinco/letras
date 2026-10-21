import 'dart:convert';

import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../models/song.dart';
import 'app_http.dart';

/// Cliente para buscar álbumes y artistas, traer el tracklist de un álbum,
/// y la discografía de un artista, usando la API pública y gratuita de
/// iTunes (la misma que ya se usa para las carátulas: no requiere API key
/// ni login, así que funciona igual estés o no conectado a Spotify).
class ItunesCatalogService {
  static const _host = 'itunes.apple.com';

  String? _bigArtwork(String? url) => url?.replaceAll('100x100', '600x600');

  Future<List<AlbumResult>> searchAlbums(String query, {int limit = 25}) async {
    if (query.trim().isEmpty) return [];
    try {
      final uri = Uri.https(_host, '/search', {
        'term': query,
        'entity': 'album',
        'limit': '$limit',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];
      return results
          .map((r) => r as Map<String, dynamic>)
          .where((r) => r['collectionId'] != null)
          .map(_albumFromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<ArtistResult>> searchArtists(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    try {
      final uri = Uri.https(_host, '/search', {
        'term': query,
        'entity': 'musicArtist',
        'limit': '$limit',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];
      return results
          .map((r) => r as Map<String, dynamic>)
          .where((r) => r['artistId'] != null)
          .map((r) => ArtistResult(
                artistId: r['artistId'] as int,
                name: r['artistName'] as String? ?? '',
                genre: r['primaryGenreName'] as String?,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Canciones de un álbum, ordenadas por número de pista.
  Future<List<Song>> getAlbumTracks(int collectionId) async {
    try {
      final uri = Uri.https(_host, '/lookup', {
        'id': '$collectionId',
        'entity': 'song',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];

      final tracks = results
          .map((r) => r as Map<String, dynamic>)
          .where((r) => r['wrapperType'] == 'track' && r['kind'] == 'song')
          .map((r) => Song(
                title: r['trackName'] as String? ?? '',
                artist: r['artistName'] as String? ?? '',
                album: r['collectionName'] as String?,
                durationSeconds: ((r['trackTimeMillis'] as num?)?.toInt() ?? 0) ~/ 1000,
                artworkUrl: _bigArtwork(r['artworkUrl100'] as String?),
                trackNumber: (r['trackNumber'] as num?)?.toInt(),
              ))
          .toList();

      tracks.sort((a, b) => (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0));
      return tracks;
    } catch (_) {
      return [];
    }
  }

  /// Discografía de un artista (álbumes), del más nuevo al más viejo.
  Future<List<AlbumResult>> getArtistAlbums(int artistId) async {
    try {
      final uri = Uri.https(_host, '/lookup', {
        'id': '$artistId',
        'entity': 'album',
        'limit': '200',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];

      final albums = results
          .map((r) => r as Map<String, dynamic>)
          .where((r) => r['wrapperType'] == 'collection' && r['collectionId'] != null)
          .map(_albumFromJson)
          .toList();

      albums.sort((a, b) => (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
      return albums;
    } catch (_) {
      return [];
    }
  }

  /// La búsqueda de artistas de iTunes no trae foto: como respaldo, usamos
  /// la carátula de su álbum más reciente.
  Future<String?> fetchArtistArtwork(int artistId) async {
    final albums = await getArtistAlbums(artistId);
    if (albums.isEmpty) return null;
    return albums.first.artworkUrl;
  }

  AlbumResult _albumFromJson(Map<String, dynamic> json) {
    return AlbumResult(
      collectionId: json['collectionId'] as int,
      title: json['collectionName'] as String? ?? '',
      artist: json['artistName'] as String? ?? '',
      artworkUrl: _bigArtwork(json['artworkUrl100'] as String?),
      releaseDate: json['releaseDate'] as String?,
      trackCount: (json['trackCount'] as num?)?.toInt(),
    );
  }
}
