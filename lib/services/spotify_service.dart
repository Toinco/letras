import 'dart:convert';

import '../models/song.dart';
import '../utils/text_normalize.dart';
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

/// Un dispositivo donde puede sonar Spotify (este teléfono, la compu...).
class SpotifyDevice {
  final String id;
  final String name;
  final String type; // Computer, Smartphone, Speaker...
  final bool isActive;

  const SpotifyDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isActive,
  });
}

/// Lo que dice Spotify cuando la cuenta no está agregada en "User
/// Management" de la app de developer.spotify.com (modo desarrollo).
const spotifyNotRegisteredMessage =
    'Tu cuenta de Spotify no está habilitada en tu app de Spotify Developer. Entra a '
    'developer.spotify.com/dashboard, abre tu app, ve a "User Management" y agrega el '
    'nombre y el email de tu cuenta de Spotify.';

bool _notRegistered(String body) => body.contains('not registered');

/// Error de reproducción con un mensaje para mostrar tal cual.
class SpotifyPlaybackException implements Exception {
  final String message;
  final int? status;

  const SpotifyPlaybackException(this.message, {this.status});

  @override
  String toString() => message;
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
      spotifyUri: track['uri'] as String?,
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
      if (_notRegistered(response.body)) throw const SpotifyPlaybackException(spotifyNotRegisteredMessage);
      throw Exception('Spotify no dio permiso para esto. Reconecta tu cuenta en Ajustes.');
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

  // ------------------------------------------------------------ búsqueda

  /// Ya buscadas (artista|título -> canción de Spotify o null), para no
  /// buscar dos veces.
  static final Map<String, Song?> _found = {};

  /// Busca [song] en el catálogo de Spotify y devuelve la que mejor
  /// coincide (título, artista y duración), o null.
  Future<Song?> findTrack(Song song) async {
    if (song.spotifyUri != null) return song;
    final key = '${normalizeForSearch(song.artist)}|${normalizeForSearch(song.title)}';
    if (_found.containsKey(key)) return _found[key];
    final title = cleanTitleForMatching(song.title);
    final artist = primaryArtistName(song.artist);
    final queries = [
      'track:"$title" artist:"$artist"',
      '$title $artist',
    ];
    for (final q in queries) {
      final json = await _getJson(Uri.https('api.spotify.com', '/v1/search', {
        'q': q,
        'type': 'track',
        'limit': '10',
      }));
      final items = (json['tracks']?['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(songFromTrack)
          .toList();
      final best = bestMatch(song, items);
      if (best != null) {
        _found[key] = best;
        return best;
      }
    }
    _found[key] = null;
    return null;
  }

  /// La que mejor coincide con [wanted] entre [candidates] (o null si
  /// ninguna se parece lo suficiente).
  static Song? bestMatch(Song wanted, List<Song> candidates) {
    final qt = normalizeForSearch(cleanTitleForMatching(wanted.title));
    final qa = normalizeForSearch(primaryArtistName(wanted.artist));
    Song? best;
    var bestScore = 0;
    for (final c in candidates) {
      final ct = normalizeForSearch(cleanTitleForMatching(c.title));
      final ca = normalizeForSearch(c.artist);
      var score = 0;
      if (ct == qt) {
        score += 50;
      } else if (ct.isNotEmpty && qt.isNotEmpty && (ct.contains(qt) || qt.contains(ct))) {
        score += 25;
      } else {
        continue;
      }
      if (qa.isNotEmpty && (ca.contains(qa) || qa.contains(normalizeForSearch(primaryArtistName(c.artist))))) {
        score += 30;
      } else if (qa.isNotEmpty) {
        // Mismo título de otro artista: casi siempre es otra canción.
        score -= 30;
      }
      final wd = wanted.durationSeconds ?? 0;
      final cd = c.durationSeconds ?? 0;
      if (wd > 0 && cd > 0) {
        final diff = (wd - cd).abs();
        if (diff <= 3) {
          score += 10;
        } else if (diff > 20) {
          score -= 10;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return bestScore >= 45 ? best : null;
  }

  // -------------------------------------------------------- reproducción

  Future<Map<String, String>> _authHeaders() async =>
      {'Authorization': 'Bearer ${await _auth.getValidAccessToken()}'};

  /// Dispositivos donde puede sonar Spotify ahora mismo.
  Future<List<SpotifyDevice>> devices() async {
    final json = await _getJson(Uri.https('api.spotify.com', '/v1/me/player/devices'));
    return [
      for (final d in (json['devices'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
        if (d['id'] != null && d['is_restricted'] != true)
          SpotifyDevice(
            id: d['id'] as String,
            name: d['name'] as String? ?? '',
            type: d['type'] as String? ?? '',
            isActive: d['is_active'] as bool? ?? false,
          ),
    ];
  }

  /// Pone a sonar [uris] (la primera ya, las demás quedan como lista) en
  /// [deviceId] (o en el dispositivo activo).
  Future<void> playUris(List<String> uris, {String? deviceId, int offset = 0}) async {
    final uri = Uri.https('api.spotify.com', '/v1/me/player/play', {
      if (deviceId != null) 'device_id': deviceId,
    });
    final response = await AppHttp.put(
      uri,
      headers: {...await _authHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'uris': uris,
        if (offset > 0) 'offset': {'position': offset},
      }),
      tag: 'spotify',
    );
    _checkPlayer(response.statusCode, response.body);
  }

  /// ¿Está sonando [trackUri] ahora mismo?
  Future<bool> isPlaying(String trackUri) async {
    try {
      final response = await AppHttp.get(
        Uri.https('api.spotify.com', '/v1/me/player'),
        headers: await _authHeaders(),
        tag: 'spotify',
        retries: 0,
        timeout: const Duration(seconds: 4),
      );
      if (response.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return json['is_playing'] == true && (json['item'] as Map?)?['uri'] == trackUri;
    } catch (_) {
      return false;
    }
  }

  /// Agrega [trackUri] a la cola de reproducción.
  Future<void> addToQueue(String trackUri, {String? deviceId}) async {
    final uri = Uri.https('api.spotify.com', '/v1/me/player/queue', {
      'uri': trackUri,
      if (deviceId != null) 'device_id': deviceId,
    });
    final response = await AppHttp.post(uri, headers: await _authHeaders(), tag: 'spotify', retries: 1);
    _checkPlayer(response.statusCode, response.body);
  }

  static void _checkPlayer(int status, String body) {
    if (status >= 200 && status < 300) return;
    var reason = '';
    try {
      reason = (jsonDecode(body)['error']?['reason'] as String?) ?? '';
    } catch (_) {}
    if (status == 403 && _notRegistered(body)) {
      throw const SpotifyPlaybackException(spotifyNotRegisteredMessage, status: 403);
    }
    if (status == 404 || reason == 'NO_ACTIVE_DEVICE') {
      throw SpotifyPlaybackException('Spotify no está abierto en ningún dispositivo.', status: status);
    }
    if (status == 401 || (status == 403 && reason != 'PREMIUM_REQUIRED')) {
      throw SpotifyPlaybackException(
        'Falta permiso para reproducir. Reconecta Spotify en Ajustes.',
        status: status,
      );
    }
    if (reason == 'PREMIUM_REQUIRED') {
      throw SpotifyPlaybackException('Spotify pide una cuenta Premium para esto.', status: status);
    }
    throw SpotifyPlaybackException('Spotify respondió $status.', status: status);
  }

  // ---------------------------------------------------------- escuchado

  /// Lo último que sonó en Spotify (sin repetidos).
  Future<List<Song>> recentlyPlayed({int limit = 30}) async {
    final json = await _getJson(Uri.https(
      'api.spotify.com',
      '/v1/me/player/recently-played',
      {'limit': '$limit'},
    ));
    final seen = <String>{};
    final out = <Song>[];
    for (final item in (json['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
      final track = item['track'] as Map<String, dynamic>?;
      if (track == null) continue;
      final song = songFromTrack(track);
      if (song.title.isEmpty || !seen.add('${song.artist}|${song.title}'.toLowerCase())) continue;
      out.add(song);
    }
    return out;
  }

  /// Tus canciones más escuchadas en Spotify ([range]: short_term = último
  /// mes, medium_term = 6 meses, long_term = todo).
  Future<List<Song>> topTracks({String range = 'short_term', int limit = 20}) async {
    final json = await _getJson(Uri.https('api.spotify.com', '/v1/me/top/tracks', {
      'time_range': range,
      'limit': '$limit',
    }));
    return [
      for (final t in (json['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
        songFromTrack(t),
    ].where((s) => s.title.isNotEmpty).toList();
  }

  /// Tus artistas más escuchados en Spotify (nombre y foto).
  Future<List<({String name, String? imageUrl})>> topArtists({
    String range = 'short_term',
    int limit = 20,
  }) async {
    final json = await _getJson(Uri.https('api.spotify.com', '/v1/me/top/artists', {
      'time_range': range,
      'limit': '$limit',
    }));
    return [
      for (final a in (json['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
        (
          name: a['name'] as String? ?? '',
          imageUrl: ((a['images'] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?)?['url']
              as String?,
        ),
    ].where((a) => a.name.isNotEmpty).toList();
  }

  /// Tu nombre y foto de perfil en Spotify.
  Future<({String name, String? imageUrl})?> profile() async {
    try {
      final json = await _getJson(Uri.https('api.spotify.com', '/v1/me'));
      final images = json['images'] as List<dynamic>?;
      return (
        name: json['display_name'] as String? ?? '',
        imageUrl: (images?.firstOrNull as Map<String, dynamic>?)?['url'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
