import 'dart:convert';
import 'dart:typed_data';

import '../utils/text_normalize.dart';
import 'app_http.dart';

/// Busca la carátula de una canción usando la API pública y gratuita de
/// búsqueda de iTunes (no requiere API key). Se usa como respaldo cuando
/// no tenemos la carátula real desde la sesión multimedia (por ejemplo, en
/// el buscador manual, las descargas, canciones reconocidas por audio, o
/// Spotify en Windows, que entrega la tapa con su logo).
class ArtworkService {
  // Cache simple en memoria para no repetir la misma búsqueda de red.
  static final Map<String, String?> _cache = {};

  /// Para tests.
  static void clearCache() => _cache.clear();

  /// URL de la carátula (600 px) de [title] de [artist]. Si se sabe el
  /// [album] o la duración, se usan para elegir la edición correcta.
  ///
  /// Antes se usaba el primer resultado de iTunes, que muchas veces es otra
  /// canción del mismo artista (para "love is embarrassing" de Olivia
  /// Rodrigo, el primero es "good 4 u" y salía la tapa de SOUR en vez de la
  /// de GUTS). Ahora se piden varios y se elige el que coincide; si ninguno
  /// coincide, mejor sin carátula que con una equivocada.
  Future<String?> fetchArtworkUrl(
    String title,
    String artist, {
    String? album,
    int? durationSeconds,
  }) async {
    final key = [
      normalizeForSearch(artist),
      normalizeForSearch(title),
      normalizeForSearch(album ?? ''),
    ].join('|');
    if (_cache.containsKey(key)) return _cache[key];

    try {
      var results = await _search('$artist ${cleanTitleForMatching(title)}');
      var best = pickBest(results, title, artist, album: album, durationSeconds: durationSeconds);
      // Con artistas de nombre largo ("A, B & C") a veces no aparece: se
      // reintenta solo con el principal.
      final primary = primaryArtistName(artist);
      if (best == null && primary != artist.trim()) {
        results = await _search('$primary ${cleanTitleForMatching(title)}');
        best = pickBest(results, title, artist, album: album, durationSeconds: durationSeconds);
      }
      final artwork100 = best?['artworkUrl100'] as String?;
      // Pide una versión más grande que la miniatura de 100x100 por defecto.
      final artworkBig = artwork100?.replaceAll('100x100', '600x600');
      _cache[key] = artworkBig;
      return artworkBig;
    } catch (_) {
      // Error de red: no se guarda, así se reintenta la próxima vez.
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _search(String term) async {
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': term,
      'entity': 'song',
      'limit': '25',
    });
    final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
    if (response.statusCode != 200) return const [];
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return [
      for (final r in json['results'] as List<dynamic>? ?? const [])
        if (r is Map<String, dynamic>) r,
    ];
  }

  static final _coverWords = RegExp(
    r'\b(karaoke|instrumental|tribute|cover|covers|piano|lullaby|made famous|originally performed'
    r'|in the style of|8-bit|music box)\b',
  );

  /// El resultado de iTunes que es esta canción, o `null` si ninguno lo es.
  static Map<String, dynamic>? pickBest(
    List<Map<String, dynamic>> results,
    String title,
    String artist, {
    String? album,
    int? durationSeconds,
  }) {
    final qTitle = _norm(cleanTitleForMatching(title));
    final qArtist = _norm(primaryArtistName(artist));
    final qAlbum = _norm(cleanTitleForMatching(album ?? ''));
    if (qTitle.isEmpty) return null;
    // Palabras de "versión cover" que ya están en lo buscado no cuentan
    // (por ejemplo, "Piano Man").
    final queryCoverWords = _coverWords
        .allMatches(normalizeForSearch('$title $artist ${album ?? ''}'))
        .map((m) => m.group(0))
        .toSet();

    Map<String, dynamic>? best;
    var bestScore = 0;
    for (final r in results) {
      final rTitle = _norm(cleanTitleForMatching(r['trackName'] as String? ?? ''));
      final rArtist = _norm(r['artistName'] as String? ?? '');
      final rAlbum = _norm(cleanTitleForMatching(r['collectionName'] as String? ?? ''));
      if (r['artworkUrl100'] is! String) continue;

      // Título y artista tienen que coincidir sí o sí.
      var score = 0;
      if (rTitle == qTitle) {
        score += 100;
      } else if (rTitle.startsWith(qTitle) || qTitle.startsWith(rTitle)) {
        score += 50;
      } else {
        continue;
      }
      if (qArtist.isNotEmpty) {
        if (rArtist == qArtist) {
          score += 60;
        } else if (rArtist.contains(qArtist) || qArtist.contains(rArtist)) {
          score += 40;
        } else {
          continue;
        }
      }

      // El álbum es lo que distingue la edición (single, álbum, deluxe...).
      if (qAlbum.isNotEmpty) {
        if (rAlbum == qAlbum) {
          score += 80;
        } else if (rAlbum.startsWith(qAlbum) || qAlbum.startsWith(rAlbum)) {
          score += 40;
        }
      }
      final ms = r['trackTimeMillis'];
      if (durationSeconds != null && durationSeconds > 0 && ms is num) {
        final diff = (ms / 1000 - durationSeconds).abs();
        if (diff <= 2) {
          score += 20;
        } else if (diff <= 6) {
          score += 8;
        }
      }
      // Versiones karaoke, en piano, tributos...
      final rRaw = normalizeForSearch('${r['trackName']} ${r['collectionName']}');
      if (_coverWords.allMatches(rRaw).any((m) => !queryCoverWords.contains(m.group(0)))) {
        score -= 120;
      }

      // A igual puntaje queda el primero (iTunes pone antes el original).
      if (score > bestScore) {
        best = r;
        bestScore = score;
      }
    }
    return best;
  }

  /// Minúsculas, sin acentos ni signos: "Love Is Embarrassing!" ==
  /// "love is embarrassing".
  static String _norm(String s) => normalizeForSearch(s)
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Descarga los bytes reales de la carátula (para guardarla junto con
  /// una letra descargada y así verla sin conexión). Si [knownUrl] ya
  /// viene resuelto (por ejemplo, la imagen que da la propia API de
  /// Spotify), se usa directo en vez de buscarla en iTunes.
  Future<Uint8List?> fetchArtworkBytes(
    String title,
    String artist, {
    String? knownUrl,
    String? album,
    int? durationSeconds,
  }) async {
    try {
      final url = knownUrl ??
          await fetchArtworkUrl(title, artist, album: album, durationSeconds: durationSeconds);
      if (url == null) return null;
      final response = await AppHttp.get(Uri.parse(url), timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
