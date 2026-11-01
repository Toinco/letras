import 'dart:convert';
import 'dart:math';

import '../models/album_result.dart';
import '../models/song.dart';
import '../utils/text_normalize.dart';
import 'app_http.dart';
import 'itunes_catalog_service.dart';

/// Un artista para mostrar (con foto).
class DiscoveryArtist {
  final String name;
  final String? imageUrl;
  final int? deezerId;

  const DiscoveryArtist({required this.name, this.imageUrl, this.deezerId});

  Map<String, dynamic> toJson() => {'name': name, 'imageUrl': imageUrl, 'deezerId': deezerId};

  factory DiscoveryArtist.fromJson(Map<String, dynamic> j) => DiscoveryArtist(
        name: j['name'] as String? ?? '',
        imageUrl: j['imageUrl'] as String?,
        deezerId: (j['deezerId'] as num?)?.toInt(),
      );
}

/// Catálogos públicos y gratuitos (sin cuenta) para descubrir música:
///
/// - Deezer: fotos de artistas, artistas parecidos, sus canciones más
///   escuchadas y el ranking mundial.
/// - Apple Music (feeds públicos de rankings): lo más escuchado en tu país,
///   canciones y álbumes (con su id de Apple Music).
class DiscoveryService {
  static const _deezer = 'api.deezer.com';
  static const _timeout = Duration(seconds: 8);

  /// Artista de Deezer por nombre (con caché en memoria).
  static final Map<String, DiscoveryArtist?> _artists = {};

  Future<Map<String, dynamic>?> _deezerJson(String path, [Map<String, String>? query]) async {
    try {
      final response = await AppHttp.get(
        Uri.https(_deezer, path, query),
        timeout: _timeout,
        retries: 1,
        tag: 'deezer',
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, dynamic> || json['error'] != null) return null;
      return json;
    } catch (_) {
      return null;
    }
  }

  /// Busca al artista [name] en Deezer (para su foto y sus parecidos).
  Future<DiscoveryArtist?> artist(String name) async {
    final key = normalizeForSearch(primaryArtistName(name));
    if (key.isEmpty) return null;
    if (_artists.containsKey(key)) return _artists[key];
    final json = await _deezerJson('/search/artist', {'q': primaryArtistName(name), 'limit': '5'});
    if (json == null) return null; // sin red: no se guarda, se reintenta después
    DiscoveryArtist? found;
    for (final a in (json['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
      final n = a['name'] as String? ?? '';
      if (normalizeForSearch(n) == key) {
        found = _fromDeezer(a);
        break;
      }
    }
    _artists[key] = found;
    return found;
  }

  static DiscoveryArtist _fromDeezer(Map<String, dynamic> a) => DiscoveryArtist(
        name: a['name'] as String? ?? '',
        imageUrl: (a['picture_xl'] ?? a['picture_big']) as String?,
        deezerId: (a['id'] as num?)?.toInt(),
      );

  /// Artistas parecidos a [artistId] (de Deezer).
  Future<List<DiscoveryArtist>> related(int artistId, {int limit = 8}) async {
    final json = await _deezerJson('/artist/$artistId/related', {'limit': '$limit'});
    return [
      for (final a in (json?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
        _fromDeezer(a),
    ];
  }

  /// Las canciones más escuchadas de [artistId].
  Future<List<Song>> topTracks(int artistId, {int limit = 5}) async {
    final json = await _deezerJson('/artist/$artistId/top', {'limit': '$limit'});
    return _deezerSongs(json);
  }

  /// Lo más escuchado en el mundo (ranking de Deezer).
  Future<List<Song>> globalChart({int limit = 30}) async {
    final json = await _deezerJson('/chart/0/tracks', {'limit': '$limit'});
    return _deezerSongs(json);
  }

  static List<Song> _deezerSongs(Map<String, dynamic>? json) => [
        for (final t in (json?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
          Song(
            title: (t['title_short'] ?? t['title']) as String? ?? '',
            artist: (t['artist'] as Map<String, dynamic>?)?['name'] as String? ?? '',
            album: (t['album'] as Map<String, dynamic>?)?['title'] as String?,
            durationSeconds: (t['duration'] as num?)?.toInt(),
            artworkUrl: (t['album'] as Map<String, dynamic>?)?['cover_xl'] as String?,
          ),
      ].where((s) => s.title.isNotEmpty).toList();

  /// Canciones de un género o estilo: la mejor playlist de Deezer que
  /// aparece buscando [query] (prefiere las de sus editores).
  Future<List<Song>> playlistSongs(String query, {int limit = 60}) async {
    final found = await _deezerJson('/search/playlist', {'q': query, 'limit': '8'});
    final lists = (found?['data'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
    if (lists.isEmpty) return [];
    final editorial = lists.where((p) {
      final user = ((p['user'] as Map<String, dynamic>?)?['name'] as String? ?? '').toLowerCase();
      return user.contains('deezer');
    }).firstOrNull;
    final pick = editorial ?? lists.first;
    final tracks = await _deezerJson('/playlist/${pick['id']}/tracks', {'limit': '$limit'});
    final seen = <String>{};
    return _deezerSongs(tracks).where((s) => seen.add(songKey(s))).toList();
  }

  // ------------------------------------------------------ rankings de Apple

  Future<List<Map<String, dynamic>>> _appleChart(String kind, int limit) async {
    final cc = ItunesCatalogService.storefront;
    try {
      final response = await AppHttp.get(
        Uri.https(
            'rss.marketingtools.apple.com', '/api/v2/$cc/music/most-played/$limit/$kind.json'),
        timeout: _timeout,
        retries: 1,
        tag: 'apple-charts',
      );
      if (response.statusCode != 200) return [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return ((json['feed']?['results'] as List<dynamic>?) ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String? _bigArt(Object? url) =>
      (url as String?)?.replaceAll(RegExp(r'\d+x\d+bb'), '600x600bb');

  /// Lo más escuchado en Apple Music en tu país.
  Future<List<Song>> countryChart({int limit = 30}) async => [
        for (final r in await _appleChart('songs', limit))
          Song(
            title: r['name'] as String? ?? '',
            artist: r['artistName'] as String? ?? '',
            artworkUrl: _bigArt(r['artworkUrl100']),
            appleId: int.tryParse('${r['id']}'),
          ),
      ];

  /// Los álbumes más escuchados en Apple Music en tu país.
  Future<List<AlbumResult>> countryTopAlbums({int limit = 20}) async => [
        for (final r in await _appleChart('albums', limit))
          if (int.tryParse('${r['id']}') != null)
            AlbumResult(
              collectionId: int.parse('${r['id']}'),
              title: r['name'] as String? ?? '',
              artist: r['artistName'] as String? ?? '',
              artworkUrl: _bigArt(r['artworkUrl100']),
              releaseDate: r['releaseDate'] as String?,
            ),
      ];

  // ------------------------------------------------------- recomendaciones

  /// Canciones para descubrir a partir de los artistas que más escuchas
  /// ([seeds]): las más populares de artistas parecidos, sin repetir las
  /// que ya conoces ([known], ids de [songKey]).
  ///
  /// Devuelve una sección por artista semilla ("Porque escuchas X") más los
  /// artistas parecidos que encontró.
  Future<({List<({String seed, List<Song> songs})> sections, List<DiscoveryArtist> artists})>
      recommendations(List<String> seeds, Set<String> known, {int perSeed = 10}) async {
    final rnd = Random(DateTime.now().difference(DateTime(2024)).inDays);
    final sections = <({String seed, List<Song> songs})>[];
    final suggested = <String, DiscoveryArtist>{};
    final seedKeys = seeds.map((s) => normalizeForSearch(primaryArtistName(s))).toSet();
    final used = <String>{...known};

    final perSeedResults = await Future.wait(seeds.map((seed) async {
      final a = await artist(seed);
      if (a?.deezerId == null) return null;
      final rel = (await related(a!.deezerId!, limit: 10))
          .where((r) => !seedKeys.contains(normalizeForSearch(r.name)))
          .toList()
        ..shuffle(rnd);
      final picked = rel.take(5).toList();
      final tracks = await Future.wait(
        picked.where((r) => r.deezerId != null).map((r) => topTracks(r.deezerId!, limit: 4)),
      );
      return (seed: a.name, artists: picked, tracks: tracks);
    }));

    for (final r in perSeedResults) {
      if (r == null) continue;
      for (final a in r.artists) {
        suggested.putIfAbsent(normalizeForSearch(a.name), () => a);
      }
      // Intercaladas: una de cada artista por vuelta, así no quedan cuatro
      // seguidas del mismo.
      final songs = <Song>[];
      for (var round = 0; round < 4 && songs.length < perSeed; round++) {
        for (final list in r.tracks) {
          if (round >= list.length || songs.length >= perSeed) continue;
          final s = list[round];
          if (used.add(songKey(s))) songs.add(s);
        }
      }
      if (songs.length >= 3) sections.add((seed: r.seed, songs: songs));
    }
    return (sections: sections, artists: suggested.values.take(12).toList());
  }

  /// Clave para comparar canciones (sin mayúsculas, acentos ni "(Remastered)").
  static String songKey(Song s) =>
      '${normalizeForSearch(primaryArtistName(s.artist))}|${normalizeForSearch(cleanTitleForMatching(s.title))}';
}
