import 'dart:convert';

import 'app_http.dart';
import 'claude_translator.dart';
import 'settings_service.dart';

/// Traduce la letra línea por línea al idioma elegido en Ajustes (español
/// por defecto), y saca la pronunciación de letras en japonés, coreano,
/// ruso, etc.
///
/// Si en Ajustes está activada la traducción con IA y hay API key de
/// Anthropic, primero prueba con Claude (mejor con jerga y dobles
/// sentidos); si falla, sigue con lo de siempre:
///
/// Primero usa el endpoint gratuito de Google Translate (el mismo que usa
/// la extensión del navegador, sin API key): detecta el idioma solo (no
/// solo inglés: portugués, francés, coreano, lo que sea) y traduce mucho
/// mejor. Si falla, cae a MyMemory (https://mymemory.translated.net), que
/// no detecta idioma, así que ahí adivinamos español/inglés con una
/// heurística de palabras comunes.
class TranslationService {
  // Solo se cachean traducciones que salieron BIEN (incluida la lista
  // vacía, que significa "ya está en español"). Antes también se cacheaba
  // el resultado de un fallo (por ejemplo, se acabó la cuota gratuita de
  // MyMemory por hoy) como si fuera una traducción válida pero vacía, así
  // que esa canción quedaba "sin traducción" para siempre en esta sesión,
  // aunque MyMemory hubiera vuelto a andar un rato después. Ahora un
  // fallo devuelve `null` y no se guarda en caché, para poder reintentar.
  static final Map<String, List<String>> _cache = {};

  // MyMemory limita ~500 caracteres por pedido en el plan anónimo; dejamos
  // margen para no pasarnos.
  static const _maxCharsPerRequest = 450;

  static const _spanishWords = {
    'de', 'la', 'que', 'el', 'en', 'y', 'los', 'del', 'se', 'las', 'por',
    'un', 'para', 'con', 'no', 'una', 'su', 'al', 'lo', 'como', 'más',
    'pero', 'sus', 'le', 'ya', 'esta', 'este', 'esa', 'ese', 'muy', 'sin',
    'sobre', 'también', 'me', 'hasta', 'hay', 'donde', 'todo', 'nos',
    'todos', 'ni', 'mí', 'yo', 'tú', 'mi', 'tu', 'nada', 'quiero', 'eres',
    'estoy', 'está', 'soy', 'porque', 'cómo', 'qué', 'así', 'vida', 'amor',
    'corazón', 'nunca', 'siempre', 'cuando', 'tan', 'bien', 'ahora',
  };

  static const _englishWords = {
    'the', 'be', 'to', 'of', 'and', 'a', 'in', 'that', 'have', 'i', 'it',
    'for', 'not', 'on', 'with', 'he', 'as', 'you', 'do', 'at', 'this',
    'but', 'his', 'by', 'from', 'they', 'we', 'say', 'her', 'she', 'or',
    'an', 'will', 'my', 'one', 'all', 'would', 'there', 'their', 'what',
    'so', 'up', 'out', 'if', 'about', 'who', 'get', 'which', 'go', 'me',
    'your', 'love', 'know', 'like', 'just', 'don', 'baby', 'now', 'never',
    'want', 'when', 'can', 'are', 'im', 'yeah', 'oh',
  };

  /// Adivina si el texto está en español ('es') o inglés ('en') contando
  /// palabras comunes de cada idioma. Es una heurística simple, no un
  /// detector de idioma real, pero alcanza para el caso de uso de la app
  /// (canciones en español o en inglés).
  String _guessSourceLanguage(String text) {
    final words = RegExp(r'[a-záéíóúñü]+', caseSensitive: false)
        .allMatches(text.toLowerCase())
        .map((m) => m.group(0)!);

    var spanishScore = 0;
    var englishScore = 0;
    for (final w in words) {
      if (_spanishWords.contains(w)) spanishScore++;
      if (_englishWords.contains(w)) englishScore++;
    }
    // Los acentos y la ñ son una señal fuerte de español.
    if (RegExp(r'[áéíóúñ¿¡]').hasMatch(text)) spanishScore += 3;

    // Ojo con el empate: si hay pocas palabras "reconocibles" (nombres
    // propios, ad-libs, jerga), antes un 0-0 se tomaba como "ya está en
    // español" y directamente no se traducía nada. Ahora un empate (o
    // señal débil) prefiere traducir: es mucho menos molesto mostrar una
    // traducción de más que no mostrar ninguna.
    return spanishScore > englishScore ? 'es' : 'en';
  }

  /// Devuelve la traducción línea por línea (mismo orden y cantidad que
  /// [lines]), una lista vacía si el texto ya parece estar en español (no
  /// hace falta traducir), o `null` si falló de verdad (sin conexión, o se
  /// agotó la cuota gratuita de MyMemory por hoy) — en ese caso no se debe
  /// guardar como si fuera una traducción válida, para poder reintentar.
  Future<List<String>?> translateToSpanish(List<String> lines) => translate(lines, target: 'es');

  /// Traduce a [target] (código ISO: es, en, pt...). Si no se pasa, usa
  /// el idioma elegido en Ajustes. [title]/[artist] le dan contexto a la IA.
  Future<List<String>?> translate(
    List<String> lines, {
    String? target,
    String? title,
    String? artist,
  }) async {
    if (lines.isEmpty) return [];
    final tl = target ?? SettingsService.translationLang.value;
    final useAi = SettingsService.aiTranslation.value;

    final cacheKey = '$tl|${useAi ? 'ai' : 'mt'}|${lines.join('\n')}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    if (useAi) {
      final key = await SettingsService().getClaudeApiKey();
      final ai = await ClaudeTranslator().translate(
        lines,
        target: tl,
        apiKey: key,
        title: title,
        artist: artist,
      );
      if (ai != null) {
        _cache[cacheKey] = ai;
        return ai;
      }
    }

    final google = await _googleTranslate(lines, tl);
    if (google != null) {
      _cache[cacheKey] = google;
      return google;
    }
    return _myMemoryTranslate(lines, cacheKey, tl);
  }

  // ---------------- Pronunciación (romanización) ----------------

  static final Map<String, List<String>?> _romanCache = {};

  // Letras que no son del alfabeto latino: japonés, chino, coreano,
  // cirílico, griego, árabe, hebreo, tailandés, devanagari...
  static final RegExp _nonLatin = RegExp(
    r'[\u0370-\u03FF\u0400-\u04FF\u0590-\u05FF\u0600-\u06FF\u0900-\u097F'
    r'\u0E00-\u0E7F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF]',
  );

  /// ¿Vale la pena mostrar pronunciación? (si la letra tiene bastantes
  /// caracteres no latinos).
  static bool needsRomanization(List<String> lines) {
    final text = lines.join();
    if (text.isEmpty) return false;
    final count = _nonLatin.allMatches(text).length;
    return count >= 6 && count / text.replaceAll(RegExp(r'\s'), '').length > 0.2;
  }

  /// Pronunciación en letras latinas, línea por línea (romaji, romanización
  /// del coreano, transliteración del ruso...). `null` si no hace falta o
  /// si falló.
  Future<List<String>?> romanize(List<String> lines) async {
    if (!needsRomanization(lines)) return null;
    final cacheKey = lines.join('\n');
    if (_romanCache.containsKey(cacheKey)) return _romanCache[cacheKey];

    // Google devuelve la pronunciación toda en un renglón: separamos las
    // líneas con "¶", que respeta tal cual.
    const sep = ' ¶ ';
    final result = <String>[];
    try {
      final chunks = <List<String>>[];
      var buffer = <String>[];
      var len = 0;
      for (final line in lines) {
        if (buffer.isNotEmpty && len + line.length + sep.length > _googleMaxChars) {
          chunks.add(buffer);
          buffer = [];
          len = 0;
        }
        buffer.add(line);
        len += line.length + sep.length;
      }
      if (buffer.isNotEmpty) chunks.add(buffer);

      for (final chunk in chunks) {
        final safe = chunk.map((l) => l.trim().isEmpty ? '-' : l.trim()).toList();
        final roman = await _googleRoman(safe.join(sep));
        final parts = roman?.split('¶').map((p) => p.trim()).toList();
        if (parts == null || parts.length != chunk.length) {
          // No se pudo alinear: de a una línea.
          for (final line in chunk) {
            result.add(line.trim().isEmpty || !_nonLatin.hasMatch(line)
                ? ''
                : (await _googleRoman(line))?.trim() ?? '');
          }
        } else {
          for (var i = 0; i < chunk.length; i++) {
            result.add(_nonLatin.hasMatch(chunk[i]) ? parts[i] : '');
          }
        }
      }
      _romanCache[cacheKey] = result;
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _googleRoman(String text) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': 'en',
      'dt': 'rm',
    });
    final response = await AppHttp.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8'},
      body: {'q': text},
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! List || json.isEmpty || json[0] is! List) return null;
    for (final segment in json[0] as List) {
      if (segment is List && segment.length > 3 && segment[3] is String) {
        return segment[3] as String;
      }
    }
    return null;
  }

  // ---------------- Google Translate (gtx) ----------------

  static const _googleMaxChars = 1800;

  /// `null` si falló (para caer a MyMemory); lista vacía si ya está en
  /// español; si no, la traducción alineada línea por línea.
  Future<List<String>?> _googleTranslate(List<String> lines, String target) async {
    try {
      final chunks = <List<String>>[];
      var buffer = <String>[];
      var len = 0;
      for (final line in lines) {
        if (buffer.isNotEmpty && len + line.length + 1 > _googleMaxChars) {
          chunks.add(buffer);
          buffer = [];
          len = 0;
        }
        buffer.add(line);
        len += line.length + 1;
      }
      if (buffer.isNotEmpty) chunks.add(buffer);

      final results = await Future.wait(chunks.map((c) => _googleChunk(c, target)));
      if (results.any((r) => r == null)) return null;

      // Si Google detectó que la mayor parte ya está en el idioma
      // destino, no hay nada que traducir.
      final base = target.split('-').first;
      final sameChunks = results.where((r) => r!.detected?.split('-').first == base).length;
      if (sameChunks * 2 > results.length) return const [];

      return [for (final r in results) ...r!.lines];
    } catch (_) {
      return null;
    }
  }

  Future<({List<String> lines, String? detected})?> _googleChunk(
      List<String> lines, String target) async {
    const emptyMarker = '·';
    final safe = lines.map((l) => l.trim().isEmpty ? emptyMarker : l).toList();
    final joined = await _googleRaw(safe.join('\n'), target);
    if (joined == null) return null;
    final parts = joined.text.split('\n');
    if (parts.length == lines.length) {
      return (
        lines: [
          for (var i = 0; i < parts.length; i++)
            lines[i].trim().isEmpty ? '' : parts[i].trim(),
        ],
        detected: joined.detected,
      );
    }
    // Si Google juntó/separó renglones, traducimos de a uno (en paralelo).
    final single = await Future.wait(lines.map((l) async {
      if (l.trim().isEmpty) return '';
      final r = await _googleRaw(l, target);
      return r?.text.trim();
    }));
    if (single.any((r) => r == null)) return null;
    return (lines: single.cast<String>(), detected: joined.detected);
  }

  Future<({String text, String? detected})?> _googleRaw(String text, String target) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': target,
      'dt': 't',
    });
    final response = await AppHttp.post(
          uri,
          headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8'},
          body: {'q': text},
          timeout: const Duration(seconds: 10),
        );
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! List || json.isEmpty || json[0] is! List) return null;
    final buffer = StringBuffer();
    for (final segment in json[0] as List) {
      if (segment is List && segment.isNotEmpty && segment[0] is String) {
        buffer.write(segment[0] as String);
      }
    }
    final detected = json.length > 2 && json[2] is String ? json[2] as String : null;
    return (text: buffer.toString(), detected: detected);
  }

  // ---------------- MyMemory (respaldo) ----------------

  Future<List<String>?> _myMemoryTranslate(
      List<String> lines, String cacheKey, String target) async {
    // MyMemory no detecta el idioma: adivinamos entre español e inglés.
    final sourceLang = _guessSourceLanguage(lines.join(' '));
    if (sourceLang == target.split('-').first) {
      _cache[cacheKey] = const [];
      return const [];
    }

    // Primero armamos todos los bloques (chunks) de líneas...
    final chunks = <List<String>>[];
    var buffer = <String>[];
    var bufferLen = 0;
    for (final line in lines) {
      if (buffer.isNotEmpty && bufferLen + line.length + 1 > _maxCharsPerRequest) {
        chunks.add(buffer);
        buffer = [];
        bufferLen = 0;
      }
      buffer.add(line);
      bufferLen += line.length + 1;
    }
    if (buffer.isNotEmpty) chunks.add(buffer);

    // ...y los pedimos todos en paralelo en vez de uno por uno: una
    // canción típica tarda 1 sola vuelta de red en vez de varias
    // seguidas, que es lo que hacía lenta la traducción.
    final results = await Future.wait(
      chunks.map((chunk) => _translateChunk(chunk, sourceLang, target)),
    );

    // Si algún bloque falló de verdad (no solo "vino vacío"), no
    // guardamos nada en caché ni la marcamos como traducida: mejor
    // reintentar más tarde (el usuario puede tocar "Traducir" de nuevo)
    // que mostrar líneas en blanco para siempre.
    if (results.any((r) => r == null)) {
      return null;
    }

    final translated = <String>[for (final chunk in results) ...chunk!];
    _cache[cacheKey] = translated;
    return translated;
  }

  /// `null` = falló de verdad (red, cuota agotada, etc.). Lista (aunque
  /// tenga strings vacíos por líneas que ya venían vacías) = éxito.
  Future<List<String>?> _translateChunk(
      List<String> lines, String sourceLang, String target) async {
    // Las líneas vacías rompen la separación por saltos de línea de la API,
    // así que las reemplazamos por un marcador y las restauramos después.
    const emptyMarker = '·';
    final safeLines = lines.map((l) => l.trim().isEmpty ? emptyMarker : l).toList();
    final joined = safeLines.join('\n');

    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': joined,
        'langpair': '$sourceLang|$target',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 12));
      if (response.statusCode != 200) {
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      // MyMemory devuelve responseStatus como número o como texto según el
      // caso, así que lo comparamos como string para cubrir ambos.
      if (json['responseStatus']?.toString() != '200') {
        return null;
      }

      final text = json['responseData']?['translatedText'] as String? ?? '';
      // Cuando se acaba la cuota gratuita diaria, MyMemory NO devuelve un
      // error: responde 200 con un texto de advertencia en vez de la
      // traducción real. Antes esto se guardaba tal cual (o como bloque
      // "vacío"), y la canción quedaba sin traducción para siempre en esta
      // sesión. Ahora lo detectamos y lo tratamos como un fallo real.
      if (_looksLikeQuotaWarning(text)) {
        return null;
      }
      final parts = text.split('\n');

      if (parts.length == lines.length) {
        return parts.map((p) => p.trim() == emptyMarker ? '' : p).toList();
      }
      // Si la cantidad de líneas no coincide (la API a veces junta u omite
      // saltos), en vez de descartar el bloque entero (que dejaba esas
      // líneas sin traducir), traducimos una por una: más lento para ese
      // bloque puntual, pero no se pierde la traducción.
      final singleResults = await Future.wait(
        lines.map((l) => _translateSingleLine(l, sourceLang, target)),
      );
      if (singleResults.any((r) => r == null)) return null;
      return singleResults.map((r) => r!).toList();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _translateSingleLine(String line, String sourceLang, String target) async {
    if (line.trim().isEmpty) return '';
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': line,
        'langpair': '$sourceLang|$target',
      });
      final response = await AppHttp.get(uri, timeout: const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['responseStatus']?.toString() != '200') return null;
      final text = json['responseData']?['translatedText'] as String? ?? '';
      if (_looksLikeQuotaWarning(text)) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeQuotaWarning(String text) {
    final upper = text.toUpperCase();
    return upper.contains('MYMEMORY WARNING') ||
        upper.contains('QUOTA') ||
        upper.contains('IS AN INVALID') ||
        upper.contains('INVALID SOURCE LANGUAGE') ||
        upper.contains('AMOUNT OF WORDS TRANSLATED');
  }
}
