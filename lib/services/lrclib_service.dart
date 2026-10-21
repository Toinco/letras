import 'dart:convert';

import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../utils/lrc_parser.dart';
import '../utils/text_normalize.dart';
import 'app_http.dart';

/// Varias versiones de LRCLIB de la misma canción (mismo título y artista
/// principal), agrupadas para no mostrar 5 veces "Blinding Lights".
/// [best] es la que se muestra: la que tiene mejor sincronización.
class LyricsGroup {
  final LyricsResult best;
  final List<LyricsResult> versions;

  const LyricsGroup(this.best, this.versions);

  int get count => versions.length;
}

/// Cliente para la API pública y gratuita de LRCLIB (https://lrclib.net),
/// que devuelve letras planas y letras sincronizadas (formato LRC) en
/// varios idiomas, incluidos español e inglés. No requiere API key.
class LrclibService {
  static const _baseUrl = 'lrclib.net';

  // LRCLIB pide identificar la app en el User-Agent como buena práctica.
  static const _headers = {'User-Agent': AppHttp.userAgent};

  // Cache simple en memoria: si detectamos la misma canción varias veces
  // (por ejemplo, al volver a la pestaña "Reproduciendo"), no volvemos a
  // pedirla por red.
  static final Map<String, LyricsResult?> _bestMatchCache = {};

  /// Busca coincidencias por título (y opcionalmente artista/álbum).
  /// Es una búsqueda flexible: devuelve varios resultados posibles.
  Future<List<LyricsResult>> search({
    required String trackName,
    String? artistName,
    String? albumName,
  }) async {
    final uri = Uri.https(_baseUrl, '/api/search', {
      'track_name': trackName,
      if (artistName != null && artistName.trim().isNotEmpty) 'artist_name': artistName,
      if (albumName != null && albumName.trim().isNotEmpty) 'album_name': albumName,
    });

    final response = await AppHttp.get(uri, headers: _headers, tag: 'lrclib');
    if (response.statusCode != 200) {
      throw Exception('LRCLIB respondió ${response.statusCode}');
    }

    final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
    return data.map((e) => fromLrclibJson(e as Map<String, dynamic>)).toList();
  }

  /// Búsqueda libre por un solo texto: LRCLIB lo compara contra título,
  /// artista y álbum (la API pública no permite buscar por el contenido
  /// de la letra en sí, solo por esos metadatos).
  Future<List<LyricsResult>> searchGeneral(String query) async {
    final uri = Uri.https(_baseUrl, '/api/search', {'q': query});
    final response = await AppHttp.get(uri, headers: _headers, tag: 'lrclib');
    if (response.statusCode != 200) {
      throw Exception('LRCLIB respondió ${response.statusCode}');
    }
    final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
    return data.map((e) => fromLrclibJson(e as Map<String, dynamic>)).toList();
  }

  /// Agrupa resultados repetidos (misma canción, mismo artista principal,
  /// distintas subidas a LRCLIB). Respeta el orden en que aparecen.
  static List<LyricsGroup> groupVersions(List<LyricsResult> results) {
    final groups = <String, List<LyricsResult>>{};
    for (final r in results) {
      final key = '${normalizeForSearch(cleanTitleForMatching(r.song.title))}|||'
          '${normalizeForSearch(primaryArtistName(r.song.artist))}';
      groups.putIfAbsent(key, () => []).add(r);
    }
    int quality(LyricsResult r) =>
        (r.hasWordSync ? 4 : 0) +
        (r.hasSyncedLyrics ? 2 : 0) +
        (r.plainLyrics.trim().isNotEmpty ? 1 : 0);
    return [
      for (final list in groups.values)
        LyricsGroup(
          list.reduce((a, b) => quality(b) > quality(a) ? b : a),
          list,
        ),
    ];
  }

  /// Intenta encontrar la mejor coincidencia para una canción. Dispara en
  /// paralelo la búsqueda exacta (/api/get) y la flexible (/api/search)
  /// con el título/artista tal cual llegaron, y —si el título parece
  /// tener sufijos como "(feat. ...)", "(Live)" o "- Remasterizado 2011"—
  /// también con una versión "limpia".
  ///
  /// Antes, si el reconocimiento de audio o la detección automática
  /// devolvían un título con alguno de esos sufijos (algo muy común: AudD
  /// y las apps de música casi siempre agregan "feat." o "Remastered" al
  /// título), LRCLIB no encontraba nada exacto y esta función se quedaba
  /// con el primer resultado "flexible" solamente — que muchas veces era de
  /// otra canción. Ahora se puntúan todos los candidatos que aparezcan
  /// (exactos y flexibles, con título tal cual y limpio) contra el
  /// título/artista originales, y se elige el que mejor puntúa.
  Future<LyricsResult?> getBestMatch({
    required String trackName,
    required String artistName,
    String? albumName,
    int? durationSeconds,
  }) async {
    final cacheKey =
        '${trackName.toLowerCase().trim()}|${artistName.toLowerCase().trim()}|${durationSeconds ?? ''}';
    if (_bestMatchCache.containsKey(cacheKey)) {
      return _bestMatchCache[cacheKey];
    }

    final cleanedTitle = cleanTitleForMatching(trackName);
    final cleanedArtist = primaryArtistName(artistName);
    final useCleanedTitle =
        cleanedTitle.isNotEmpty && cleanedTitle.toLowerCase() != trackName.trim().toLowerCase();
    final useCleanedArtist =
        cleanedArtist.isNotEmpty && cleanedArtist.toLowerCase() != artistName.trim().toLowerCase();

    final exactFutures = <Future<LyricsResult?>>[
      _tryExactGet(
        trackName: trackName,
        artistName: artistName,
        albumName: albumName,
        durationSeconds: durationSeconds,
      ),
    ];
    // Si alguna búsqueda falla por red, NO cacheamos un "no hay letra":
    // antes, abrir la app sin conexión dejaba la canción marcada como "sin
    // letra" hasta reiniciar la app, aunque volviera internet.
    var hadNetworkError = false;
    List<LyricsResult> onSearchError(Object _) {
      hadNetworkError = true;
      return <LyricsResult>[];
    }

    final searchFutures = <Future<List<LyricsResult>>>[
      search(trackName: trackName, artistName: artistName, albumName: albumName)
          .catchError(onSearchError),
    ];

    if (useCleanedTitle || useCleanedArtist) {
      final tryTitle = useCleanedTitle ? cleanedTitle : trackName;
      final tryArtist = useCleanedArtist ? cleanedArtist : artistName;
      exactFutures.add(_tryExactGet(
        trackName: tryTitle,
        artistName: tryArtist,
        durationSeconds: durationSeconds,
      ));
      searchFutures.add(
        search(trackName: tryTitle, artistName: tryArtist).catchError(onSearchError),
      );
    }

    final exactResults = await Future.wait(exactFutures);
    final exact = exactResults.firstWhere((r) => r != null, orElse: () => null);

    final searchResultLists = await Future.wait(searchFutures);
    final flexible = <LyricsResult>[for (final list in searchResultLists) ...list];

    // Si además de la coincidencia exacta hay resultados flexibles, elegimos
    // entre todos igual (a veces la "exacta" es una versión instrumental o
    // sin letra sincronizada, y una flexible es mejor).
    final candidates = <LyricsResult>[if (exact != null) exact, ...flexible];
    if (candidates.isEmpty) {
      if (!hadNetworkError) _bestMatchCache[cacheKey] = null;
      return null;
    }

    candidates.sort((a, b) => _matchScore(b, trackName, artistName, durationSeconds)
        .compareTo(_matchScore(a, trackName, artistName, durationSeconds)));

    final best = candidates.first;
    // Un candidato que no se parece en nada (ni título ni artista) es peor
    // que no mostrar nada: antes aparecía la letra de otra canción.
    if (!_plausible(best, trackName, durationSeconds)) {
      if (!hadNetworkError) _bestMatchCache[cacheKey] = null;
      return null;
    }
    _bestMatchCache[cacheKey] = best;
    return best;
  }

  /// Puntúa qué tan bien [r] coincide con el título/artista/duración
  /// buscados: más puntos por título y artista iguales (comparando
  /// versiones "limpias", sin acentos ni sufijos), un plus si trae letra
  /// sincronizada, y un plus si la duración es parecida.
  int _matchScore(LyricsResult r, String title, String artist, int? durationSeconds) {
    var score = 0;
    final rTitle = normalizeForSearch(cleanTitleForMatching(r.song.title));
    final qTitle = normalizeForSearch(cleanTitleForMatching(title));
    final rArtist = normalizeForSearch(primaryArtistName(r.song.artist));
    final qArtist = normalizeForSearch(primaryArtistName(artist));

    if (qTitle.isNotEmpty && rTitle == qTitle) {
      score += 50;
    } else if (qTitle.isNotEmpty && (rTitle.contains(qTitle) || qTitle.contains(rTitle))) {
      score += 25;
    }
    if (qArtist.isNotEmpty && rArtist == qArtist) {
      score += 30;
    } else if (qArtist.isNotEmpty && (rArtist.contains(qArtist) || qArtist.contains(rArtist))) {
      score += 15;
    }
    if (r.hasSyncedLyrics) score += 10;
    if (r.hasWordSync) score += 3;
    // Resultados sin letra (vacíos o marcados instrumentales) casi nunca
    // son lo que se busca: que pierdan contra cualquier otro con letra.
    if (r.plainLyrics.trim().isEmpty && !r.hasSyncedLyrics) score -= 40;
    if (durationSeconds != null && durationSeconds > 0 && r.song.durationSeconds != null) {
      final diff = (r.song.durationSeconds! - durationSeconds).abs();
      if (diff <= 2) {
        score += 8;
      } else if (diff <= 5) {
        score += 4;
      }
    }
    return score;
  }

  /// El título tiene que parecerse al menos un poco, salvo que la duración
  /// coincida casi exacta (títulos traducidos/transliterados, etc.).
  bool _plausible(LyricsResult r, String title, int? durationSeconds) {
    final rTitle = normalizeForSearch(cleanTitleForMatching(r.song.title));
    final qTitle = normalizeForSearch(cleanTitleForMatching(title));
    if (qTitle.isEmpty || rTitle.contains(qTitle) || qTitle.contains(rTitle)) return true;
    if (durationSeconds != null && durationSeconds > 0 && r.song.durationSeconds != null) {
      return (r.song.durationSeconds! - durationSeconds).abs() <= 2;
    }
    return false;
  }

  Future<LyricsResult?> _tryExactGet({
    required String trackName,
    required String artistName,
    String? albumName,
    int? durationSeconds,
  }) async {
    try {
      final uri = Uri.https(_baseUrl, '/api/get', {
        'track_name': trackName,
        'artist_name': artistName,
        if (albumName != null && albumName.trim().isNotEmpty) 'album_name': albumName,
        if (durationSeconds != null && durationSeconds > 0) 'duration': durationSeconds.toString(),
      });
      final response = await AppHttp.get(uri, headers: _headers, tag: 'lrclib', retries: 1);
      if (response.statusCode == 200) {
        return fromLrclibJson(jsonDecode(utf8.decode(response.bodyBytes)));
      }
    } catch (_) {
      // Si falla la búsqueda exacta, nos quedamos solo con la flexible.
    }
    return null;
  }

  static LyricsResult fromLrclibJson(Map<String, dynamic> json) {
    final plain = json['plainLyrics'] as String? ?? '';
    final syncedRaw = json['syncedLyrics'] as String?;
    // Si LRCLIB tiene la letra sincronizada por palabra, viene en el campo
    // "lyricsfile" (YAML). Si no se puede leer, usamos el LRC de siempre.
    final lyricsfile = json['lyricsfile'] as String?;
    final wordLines = (json['hasWordSync'] == true && lyricsfile != null)
        ? LrcParser.parseLyricsfile(lyricsfile)
        : null;

    return LyricsResult(
      lrclibId: (json['id'] as num?)?.toInt(),
      song: Song(
        title: json['trackName'] as String? ?? '',
        artist: json['artistName'] as String? ?? '',
        album: json['albumName'] as String?,
        durationSeconds: (json['duration'] as num?)?.round(),
      ),
      plainLyrics: plain,
      instrumental: json['instrumental'] as bool? ?? false,
      syncedLyrics: wordLines ??
          ((syncedRaw != null && syncedRaw.trim().isNotEmpty)
              ? LrcParser.parse(syncedRaw)
              : const []),
    );
  }
}
