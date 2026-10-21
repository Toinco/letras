import 'dart:convert';
import 'dart:typed_data';
import 'app_http.dart';

/// Busca la carátula de una canción usando la API pública y gratuita de
/// búsqueda de iTunes (no requiere API key). Se usa como respaldo cuando
/// no tenemos la carátula real desde la sesión multimedia (por ejemplo, en
/// el buscador manual, las descargas, o canciones reconocidas por audio).
class ArtworkService {
  // Cache simple en memoria para no repetir la misma búsqueda de red.
  static final Map<String, String?> _cache = {};

  Future<String?> fetchArtworkUrl(String title, String artist) async {
    final key = '${artist.toLowerCase().trim()}|${title.toLowerCase().trim()}';
    if (_cache.containsKey(key)) return _cache[key];

    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': '$artist $title',
        'entity': 'song',
        'limit': '1',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _cache[key] = null;
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];
      if (results.isEmpty) {
        _cache[key] = null;
        return null;
      }

      final artwork100 = results.first['artworkUrl100'] as String?;
      // Pide una versión más grande que la miniatura de 100x100 por defecto.
      final artworkBig = artwork100?.replaceAll('100x100', '600x600');
      _cache[key] = artworkBig;
      return artworkBig;
    } catch (_) {
      _cache[key] = null;
      return null;
    }
  }

  /// Descarga los bytes reales de la carátula (para guardarla junto con
  /// una letra descargada y así verla sin conexión). Si [knownUrl] ya
  /// viene resuelto (por ejemplo, la imagen que da la propia API de
  /// Spotify), se usa directo en vez de buscarla en iTunes.
  Future<Uint8List?> fetchArtworkBytes(String title, String artist, {String? knownUrl}) async {
    try {
      final url = knownUrl ?? await fetchArtworkUrl(title, artist);
      if (url == null) return null;
      final response = await AppHttp.get(Uri.parse(url), timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
