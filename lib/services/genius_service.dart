import 'dart:convert';

import '../utils/text_normalize.dart';
import 'app_http.dart';

/// Info de una canción tal como la tiene Genius: una reseña/explicación de
/// qué trata (si existe), quién la escribió, cuándo salió, etc. Se usa
/// para la sección "Info" de la pantalla de letra (lo que el usuario pidió
/// como "sección especializada que hable sobre el tema, qué significa,
/// etc.").
class SongInfo {
  final String? description;
  final List<String> writers;
  final List<String> producers;
  final String? releaseDate;
  final String? albumName;
  final String? artworkUrl;
  final String? geniusUrl;

  const SongInfo({
    this.description,
    this.writers = const [],
    this.producers = const [],
    this.releaseDate,
    this.albumName,
    this.artworkUrl,
    this.geniusUrl,
  });

  bool get isEmpty =>
      (description == null || description!.trim().isEmpty) &&
      writers.isEmpty &&
      producers.isEmpty &&
      releaseDate == null;
}

/// Cliente de la API de Genius (https://docs.genius.com), usada para traer
/// la explicación/reseña que ya existe en Genius sobre una canción, más
/// datos como quién la escribió y cuándo salió.
///
/// Requiere un "Client Access Token" gratuito: el usuario crea una app en
/// genius.com/api-clients (instantáneo, sin aprobación ni tarjeta) y pega
/// ese token en Ajustes.
class GeniusService {
  static const _baseUrl = 'api.genius.com';

  // Cache simple en memoria: no repetir la misma búsqueda de red si se
  // vuelve a abrir la letra de la misma canción durante esta sesión.
  static final Map<String, SongInfo?> _cache = {};

  /// Busca la canción en Genius y trae su ficha (descripción, autores,
  /// fecha de salida). Devuelve `null` si no hay token, no se encuentra la
  /// canción, o falla la red.
  Future<SongInfo?> fetchSongInfo({
    required String apiToken,
    required String title,
    required String artist,
  }) async {
    if (apiToken.trim().isEmpty) return null;

    final cacheKey = '${artist.toLowerCase().trim()}|${title.toLowerCase().trim()}';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    try {
      final songId = await _searchSongId(apiToken, title, artist);
      if (songId == null) {
        _cache[cacheKey] = null;
        return null;
      }
      final info = await _fetchSongDetails(apiToken, songId);
      _cache[cacheKey] = info;
      return info;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _searchSongId(String token, String title, String artist) async {
    final uri = Uri.https(_baseUrl, '/search', {'q': '$title $artist'});
    final response = await AppHttp.get(uri, headers: {'Authorization': 'Bearer $token'}, timeout: const Duration(seconds: 8));
    if (response.statusCode != 200) return null;

    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final hits = (json['response']?['hits'] as List<dynamic>?) ?? [];
    if (hits.isEmpty) return null;

    final qTitle = normalizeForSearch(cleanTitleForMatching(title));
    final qArtist = normalizeForSearch(primaryArtistName(artist));

    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final hit in hits) {
      final result = hit['result'] as Map<String, dynamic>?;
      if (result == null) continue;
      final resultTitle =
          normalizeForSearch(cleanTitleForMatching(result['title'] as String? ?? ''));
      final resultArtist = normalizeForSearch(
          primaryArtistName((result['primary_artist']?['name'] as String?) ?? ''));

      var score = 0;
      if (resultTitle == qTitle) {
        score += 50;
      } else if (resultTitle.isNotEmpty &&
          (resultTitle.contains(qTitle) || qTitle.contains(resultTitle))) {
        score += 20;
      }
      if (resultArtist == qArtist) {
        score += 30;
      } else if (resultArtist.isNotEmpty &&
          (resultArtist.contains(qArtist) || qArtist.contains(resultArtist))) {
        score += 15;
      }
      if (score > bestScore) {
        bestScore = score;
        best = result;
      }
    }
    // Umbral mínimo: si nada se parece medianamente al título/artista que
    // buscamos, mejor no mostrar información de una canción equivocada.
    if (best == null || bestScore < 20) return null;
    return best['id'] as int?;
  }

  Future<SongInfo?> _fetchSongDetails(String token, int songId) async {
    final uri = Uri.https(_baseUrl, '/songs/$songId');
    final response = await AppHttp.get(uri, headers: {'Authorization': 'Bearer $token'}, timeout: const Duration(seconds: 8));
    if (response.statusCode != 200) return null;

    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final song = json['response']?['song'] as Map<String, dynamic>?;
    if (song == null) return null;

    final descriptionDom = song['description']?['dom'] as Map<String, dynamic>?;
    final description = descriptionDom != null ? _plainTextFromDom(descriptionDom).trim() : null;

    final writerArtists = (song['writer_artists'] as List<dynamic>? ?? [])
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final producerArtists = (song['producer_artists'] as List<dynamic>? ?? [])
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    return SongInfo(
      description: (description != null && description.isNotEmpty) ? description : null,
      writers: writerArtists,
      producers: producerArtists,
      releaseDate: song['release_date'] as String?,
      albumName: (song['album'] as Map<String, dynamic>?)?['name'] as String?,
      artworkUrl: song['song_art_image_url'] as String?,
      geniusUrl: song['url'] as String?,
    );
  }

  /// Convierte el árbol DOM que devuelve Genius para la descripción (nodos
  /// anidados con "tag" y "children") en texto plano legible, separando
  /// párrafos con líneas en blanco y saltos simples donde corresponde.
  String _plainTextFromDom(Map<String, dynamic> root) {
    final buffer = StringBuffer();
    _walkDom(root, buffer);
    return buffer.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  void _walkDom(dynamic node, StringBuffer buffer) {
    if (node is String) {
      buffer.write(node);
      return;
    }
    if (node is! Map<String, dynamic>) return;

    final tag = node['tag'] as String?;
    final children = node['children'] as List<dynamic>? ?? [];

    if (tag == 'br') {
      buffer.write('\n');
      return;
    }

    for (final child in children) {
      _walkDom(child, buffer);
    }

    if (tag == 'p' || tag == 'li') {
      buffer.write('\n\n');
    }
  }
}
