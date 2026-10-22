import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_http.dart';
import 'claude_translator.dart';
import 'error_log.dart';
import 'settings_service.dart';

/// Traduce la letra línea por línea al idioma elegido en Ajustes (español
/// por defecto), y saca la pronunciación de letras en japonés, coreano,
/// ruso, etc.
///
/// Cómo se pide una traducción (y por qué así):
///
/// - **Una sola vez por canción.** La letra entera se manda en bloques
///   grandes (no línea por línea). Si dos partes de la app piden la misma
///   traducción a la vez (la pantalla, la descarga automática, la
///   sincronización de favoritos...), comparten el mismo pedido.
/// - **Caché en memoria y en disco.** Lo que salió bien se guarda y la
///   próxima vez aparece al instante, aunque no haya conexión.
/// - **Límite de pedidos simultáneos.** Antes, si Google devolvía un bloque
///   desalineado, se pedía cada línea por separado y todas a la vez (60
///   pedidos juntos): Google respondía "demasiados pedidos" y la traducción
///   fallaba "cuando quería". Ahora hay como mucho 2 pedidos a la vez y un
///   bloque desalineado se parte en mitades.
/// - **Reintentos con espera** (1 s, 2 s, 4 s) antes de darse por vencido.
/// - **Cancelable**: al cambiar de canción, lo pendiente se descarta y deja
///   de mandar pedidos (ver [TranslationCancelToken]).
///
/// Proveedores: si en Ajustes está activada la traducción con IA y hay API
/// key de Anthropic, se usa Claude (mejor con jerga y dobles sentidos).
/// Como Claude tarda bastante, [translateLive] muestra primero la
/// traducción automática y la reemplaza por la de la IA cuando llega. La
/// traducción automática es el endpoint gratuito de Google Translate (sin
/// API key, detecta el idioma solo) y, si falla, MyMemory.
class TranslationService {
  TranslationService({TranslationDiskCache? disk, ClaudeTranslator? claude})
      : _disk = disk ?? defaultDiskCache,
        _claude = claude ?? ClaudeTranslator();

  /// Dónde se guarda la caché en disco. En los tests se reemplaza por una
  /// en memoria.
  static TranslationDiskCache defaultDiskCache = FileTranslationDiskCache();

  final TranslationDiskCache _disk;
  final ClaudeTranslator _claude;

  // ---------------- Caché, pedidos compartidos y límites ----------------

  /// Caché en memoria (las más usadas recientemente). Solo guarda
  /// traducciones que salieron BIEN (incluida la lista vacía, que significa
  /// "ya está en el idioma elegido"): un fallo devuelve `null` y no se
  /// guarda, para poder reintentar.
  static final LinkedHashMap<String, List<String>> _memory = LinkedHashMap();
  static const _memoryMax = 200;

  /// Pedidos en curso, por clave: si alguien pide lo mismo, se suma.
  static final Map<String, _Job> _inFlight = {};

  static final _googleLimiter = _Limiter(2);
  static final _myMemoryLimiter = _Limiter(1);
  static final _aiLimiter = _Limiter(2);

  /// Si la IA falla (sin crédito, key inválida, caída), no se la vuelve a
  /// probar por un rato: antes cada canción esperaba hasta 3 minutos a que
  /// la IA fallara antes de mostrar algo.
  static DateTime? _aiCooldownUntil;
  static const _aiCooldown = Duration(minutes: 5);

  /// Intentos por bloque antes de darse por vencido.
  static const _attempts = 4;

  /// Espera entre intentos: 2 × la de [AppHttp] (1 s, 2 s, 4 s). En los
  /// tests [AppHttp.retryDelay] es cero, así que no se espera.
  static Duration get _retryBase => AppHttp.retryDelay * 2;

  @visibleForTesting
  static void resetForTests() {
    _memory.clear();
    _inFlight.clear();
    _aiCooldownUntil = null;
  }

  /// Clave de caché: proveedor + idioma + huella del texto.
  static String cacheKey(List<String> lines, String target, String provider) {
    final digest = sha1.convert(utf8.encode(lines.join('\n')));
    return '$provider|$target|${lines.length}|$digest';
  }

  static List<String>? _memoryGet(String key) {
    final hit = _memory.remove(key);
    if (hit != null) _memory[key] = hit; // la pasamos al final (más reciente)
    return hit;
  }

  static void _memoryPut(String key, List<String> lines) {
    _memory.remove(key);
    _memory[key] = List.unmodifiable(lines);
    while (_memory.length > _memoryMax) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// Devuelve [translated] solo si está alineada con una letra de
  /// [lineCount] líneas (misma cantidad, o vacía = "ya está en el idioma").
  /// Si no coincide, `null`: mostrarla correría las traducciones de línea
  /// y quedarían desincronizadas con la letra.
  static List<String>? alignedTo(List<String>? translated, int lineCount) {
    if (translated == null) return null;
    if (translated.isEmpty || translated.length == lineCount) return translated;
    return null;
  }

  /// La traducción si ya está en memoria (sin red ni disco). Sirve para
  /// mostrarla al instante sin pasar por "cargando".
  List<String>? peekCached(List<String> lines, {String? target, bool? useAi}) {
    final tl = target ?? SettingsService.translationLang.value;
    final ai = useAi ?? SettingsService.aiTranslation.value;
    if (ai) {
      final hit = _memoryGet(cacheKey(lines, tl, 'ai'));
      if (hit != null) return hit;
    }
    return _memoryGet(cacheKey(lines, tl, 'mt'));
  }

  /// Corre [run] una sola vez por [key]: si ya está en memoria lo devuelve,
  /// si alguien más lo está pidiendo se suma a ese pedido, si está en disco
  /// lo lee de ahí. Con [cancel], el que llama deja de esperar al cancelar;
  /// si nadie más espera, el pedido deja de mandar más pedidos a la red.
  Future<List<String>?> _shared(
    String key,
    Future<({List<String> lines, bool persist})?> Function(_Job job) run, {
    TranslationCancelToken? cancel,
  }) async {
    final mem = _memoryGet(key);
    if (mem != null) return mem;
    if (cancel?.isCancelled ?? false) return null;

    var job = _inFlight[key];
    if (job == null || job.cancelled) {
      final j = _Job();
      job = j;
      _inFlight[key] = j;
      j.future = () async {
        try {
          final fromDisk = await _diskRead(key);
          if (fromDisk != null) {
            _memoryPut(key, fromDisk);
            return fromDisk;
          }
          final out = await run(j);
          if (out == null) return null;
          // Aunque ya nadie espere, si la traducción salió la guardamos:
          // el trabajo ya está hecho.
          _memoryPut(key, out.lines);
          if (out.persist) unawaited(_diskWrite(key, out.lines));
          return out.lines;
        } catch (e, st) {
          ErrorLog.record('traducción', e, st);
          return null;
        } finally {
          if (identical(_inFlight[key], j)) _inFlight.remove(key);
        }
      }();
    }

    job.waiters++;
    if (cancel == null) return job.future;
    final result = await Future.any<List<String>?>([
      job.future,
      cancel.whenCancelled.then((_) => null),
    ]);
    if (cancel.isCancelled) {
      job.waiters--;
      if (job.waiters <= 0) job.cancelled = true;
      return null;
    }
    return result;
  }

  Future<List<String>?> _diskRead(String key) async {
    try {
      return await _disk.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _diskWrite(String key, List<String> lines) async {
    try {
      await _disk.write(key, lines);
    } catch (_) {}
  }

  /// Llama a [attempt] hasta [_attempts] veces, esperando cada vez un poco
  /// más entre intento e intento. Corta antes si el pedido se canceló.
  static Future<T?> _withRetries<T>(Future<T?> Function() attempt, _Job job) async {
    for (var i = 0; i < _attempts; i++) {
      if (job.cancelled) return null;
      try {
        final r = await attempt();
        if (r != null) return r;
      } catch (_) {}
      if (i < _attempts - 1 && !job.cancelled) {
        await Future.delayed(_retryBase * (1 << i));
      }
    }
    return null;
  }

  // ---------------- API pública ----------------

  /// Devuelve la traducción línea por línea (mismo orden y cantidad que
  /// [lines]), una lista vacía si el texto ya parece estar en español (no
  /// hace falta traducir), o `null` si falló de verdad.
  Future<List<String>?> translateToSpanish(List<String> lines) => translate(lines, target: 'es');

  /// Traduce a [target] (código ISO: es, en, pt...). Si no se pasa, usa
  /// el idioma elegido en Ajustes. [title]/[artist] le dan contexto a la IA.
  ///
  /// Devuelve la traducción (misma cantidad de líneas que [lines]), una
  /// lista vacía si ya está en ese idioma, o `null` si falló (o si se
  /// canceló con [cancel]).
  Future<List<String>?> translate(
    List<String> lines, {
    String? target,
    String? title,
    String? artist,
    bool? useAi,
    TranslationCancelToken? cancel,
  }) async {
    if (lines.isEmpty) return const [];
    final tl = target ?? SettingsService.translationLang.value;
    if (useAi ?? SettingsService.aiTranslation.value) {
      final ai = await _aiTranslate(lines, tl, title, artist, cancel);
      if (ai != null || (cancel?.isCancelled ?? false)) return ai;
    }
    return _machineTranslate(lines, tl, cancel);
  }

  /// Como [translate], pero pensado para la pantalla: si la IA está
  /// activada, primero emite la traducción automática (rápida, marcada como
  /// provisoria) y después la de la IA cuando llega. Siempre termina con
  /// una actualización final ([TranslationUpdate.isFinal]); si se cancela,
  /// no emite nada más.
  Stream<TranslationUpdate> translateLive(
    List<String> lines, {
    String? target,
    String? title,
    String? artist,
    TranslationCancelToken? cancel,
  }) async* {
    bool cancelled() => cancel?.isCancelled ?? false;
    if (lines.isEmpty) {
      yield const TranslationUpdate([], isFinal: true);
      return;
    }
    final tl = target ?? SettingsService.translationLang.value;
    final useAi = SettingsService.aiTranslation.value;

    if (!useAi) {
      final mt = await _machineTranslate(lines, tl, cancel);
      if (!cancelled()) yield TranslationUpdate(mt, isFinal: true);
      return;
    }

    final cachedAi = _memoryGet(cacheKey(lines, tl, 'ai'));
    if (cachedAi != null) {
      yield TranslationUpdate(cachedAi, isFinal: true, fromAi: true);
      return;
    }

    final aiFuture = _aiTranslate(lines, tl, title, artist, cancel);
    final mtFuture = _machineTranslate(lines, tl, cancel);
    final first = await Future.any([
      aiFuture.then((r) => (fromAi: true, lines: r)),
      mtFuture.then((r) => (fromAi: false, lines: r)),
    ]);
    if (cancelled()) return;
    if (first.fromAi && first.lines != null) {
      yield TranslationUpdate(first.lines, isFinal: true, fromAi: true);
      return;
    }

    List<String>? mt;
    if (!first.fromAi) {
      mt = first.lines;
      if (mt != null) yield TranslationUpdate(mt, isFinal: false);
    }
    final ai = await aiFuture;
    if (cancelled()) return;
    if (ai != null) {
      yield TranslationUpdate(ai, isFinal: true, fromAi: true);
      return;
    }
    mt ??= await mtFuture;
    if (!cancelled()) yield TranslationUpdate(mt, isFinal: true);
  }

  // ---------------- IA (Claude) ----------------

  Future<List<String>?> _aiTranslate(
    List<String> lines,
    String target,
    String? title,
    String? artist,
    TranslationCancelToken? cancel,
  ) {
    return _shared(cacheKey(lines, target, 'ai'), (job) async {
      final until = _aiCooldownUntil;
      if (until != null && DateTime.now().isBefore(until)) return null;
      final key = await SettingsService().getClaudeApiKey();
      if (key.trim().isEmpty) return null;
      final out = await _aiLimiter.run(() async {
        if (job.cancelled) return null;
        return _claude.translate(lines, target: target, apiKey: key, title: title, artist: artist);
      });
      if (out == null) {
        if (!job.cancelled) _aiCooldownUntil = DateTime.now().add(_aiCooldown);
        return null;
      }
      final aligned = alignedTo(out, lines.length);
      return aligned == null ? null : (lines: aligned, persist: true);
    }, cancel: cancel);
  }

  // ---------------- Traducción automática ----------------

  Future<List<String>?> _machineTranslate(
    List<String> lines,
    String target,
    TranslationCancelToken? cancel,
  ) {
    return _shared(cacheKey(lines, target, 'mt'), (job) async {
      final batch = await _googleBatchTranslate(lines, target, job);
      if (batch != null) return (lines: batch, persist: true);
      if (job.cancelled) return null;
      final google = await _googleTranslate(lines, target, job);
      if (google != null) return (lines: google, persist: true);
      if (job.cancelled) return null;
      final myMemory = await _myMemoryTranslate(lines, target, job);
      if (myMemory == null) return null;
      // "Ya está en español" de MyMemory es una adivinanza: no la
      // guardamos en disco para siempre, solo en memoria.
      return (lines: myMemory, persist: myMemory.isNotEmpty);
    }, cancel: cancel);
  }

  static List<List<String>> _chunk(List<String> lines, int maxChars, int sepLen) {
    final chunks = <List<String>>[];
    var buffer = <String>[];
    var len = 0;
    for (final line in lines) {
      if (buffer.isNotEmpty && len + line.length + sepLen > maxChars) {
        chunks.add(buffer);
        buffer = [];
        len = 0;
      }
      buffer.add(line);
      len += line.length + sepLen;
    }
    if (buffer.isNotEmpty) chunks.add(buffer);
    return chunks;
  }

  // ---------------- Pronunciación (romanización) ----------------

  // Letras que no son del alfabeto latino: japonés, chino, coreano,
  // cirílico, griego, árabe, hebreo, tailandés, devanagari...
  static final RegExp _nonLatin = RegExp(
    r'[Ͱ-ϿЀ-ӿ֐-׿؀-ۿऀ-ॿ'
    r'฀-๿぀-ヿ㐀-䶿一-鿿가-힯]',
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
  Future<List<String>?> romanize(List<String> lines, {TranslationCancelToken? cancel}) async {
    if (!needsRomanization(lines)) return null;
    return _shared(cacheKey(lines, 'latn', 'rm'), (job) async {
      // Google devuelve la pronunciación toda en un renglón: separamos las
      // líneas con "¶", que respeta tal cual.
      const sep = ' ¶ ';
      final result = <String>[];
      for (final chunk in _chunk(lines, _googleMaxChars, sep.length)) {
        if (job.cancelled) return null;
        final safe = chunk.map((l) => l.trim().isEmpty ? '-' : l.trim()).toList();
        final roman = await _withRetries(() => _googleRoman(safe.join(sep)), job);
        if (roman == null) return null;
        final parts = roman.split('¶').map((p) => p.trim()).toList();
        if (parts.length == chunk.length) {
          for (var i = 0; i < chunk.length; i++) {
            result.add(_nonLatin.hasMatch(chunk[i]) ? parts[i] : '');
          }
        } else {
          // No se pudo alinear: de a una línea (de a una por vez, sin
          // saturar a Google).
          for (final line in chunk) {
            if (job.cancelled) return null;
            result.add(line.trim().isEmpty || !_nonLatin.hasMatch(line)
                ? ''
                : (await _googleRoman(line).catchError((_) => null))?.trim() ?? '');
          }
        }
      }
      return (lines: result, persist: true);
    }, cancel: cancel);
  }

  Future<String?> _googleRoman(String text) => _googleLimiter.run(() async {
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
          retries: 0, // los reintentos los maneja _withRetries (sabe si se canceló)
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
      });

  // ---------------- Google Translate, por lotes (translate_a/t) ----------------

  static const _googleBatchMaxChars = 3500;

  /// Primera opción: el endpoint `translate_a/t` acepta varias líneas en un
  /// mismo pedido (un `q=` por línea) y devuelve una traducción por línea,
  /// siempre alineada, con el idioma detectado de cada una. Aguanta mucho
  /// mejor que `translate_a/single`, que con pocos pedidos seguidos
  /// responde "demasiados pedidos".
  ///
  /// Las líneas que ya están en el idioma destino (canciones mezcladas)
  /// quedan vacías, para no repetir la misma línea abajo. Si casi toda la
  /// canción ya está en ese idioma, devuelve lista vacía.
  Future<List<String>?> _googleBatchTranslate(List<String> lines, String target, _Job job) async {
    final chunks = _chunk(lines, _googleBatchMaxChars, 3);
    final results = await Future.wait(
      chunks.map((c) => _withRetries(() => _googleBatchRaw(c, target), job)),
    );
    if (job.cancelled || results.any((r) => r == null)) return null;
    final all = [for (final r in results) ...r!];
    if (all.length != lines.length) return null;

    final base = target.split('-').first;
    bool sameLang(String? lang) => lang?.split('-').first == base;
    final nonEmpty = [for (var i = 0; i < lines.length; i++) if (lines[i].trim().isNotEmpty) i];
    if (nonEmpty.isEmpty) return const [];
    final already = nonEmpty.where((i) => sameLang(all[i].detected)).length;
    if (already / nonEmpty.length >= 0.8) return const [];

    return [
      for (var i = 0; i < lines.length; i++)
        lines[i].trim().isEmpty || sameLang(all[i].detected) ? '' : all[i].text.trim(),
    ];
  }

  Future<List<({String text, String? detected})>?> _googleBatchRaw(
          List<String> lines, String target) =>
      _googleLimiter.run(() async {
        final uri = Uri.https('translate.googleapis.com', '/translate_a/t', {
          'client': 'gtx',
          'sl': 'auto',
          'tl': target,
        });
        // Un Map no admite claves repetidas: el cuerpo se arma a mano.
        final body = lines.map((l) => 'q=${Uri.encodeQueryComponent(l.trim())}').join('&');
        final response = await AppHttp.post(
          uri,
          headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8'},
          body: body,
          timeout: const Duration(seconds: 12),
          retries: 0, // los reintentos los maneja _withRetries (sabe si se canceló)
        );
        if (response.statusCode != 200) return null;
        final json = jsonDecode(utf8.decode(response.bodyBytes));
        if (json is! List || json.length != lines.length) return null;
        return [
          for (final e in json)
            if (e is List && e.isNotEmpty && e[0] is String)
              (text: e[0] as String, detected: e.length > 1 && e[1] is String ? e[1] as String : null)
            else if (e is String)
              (text: e, detected: null)
            else
              (text: '', detected: null),
        ];
      });

  // ---------------- Google Translate (translate_a/single, respaldo) ----------------

  static const _googleMaxChars = 1800;

  /// `null` si falló (para caer a MyMemory); lista vacía si ya está en
  /// el idioma destino; si no, la traducción alineada línea por línea.
  Future<List<String>?> _googleTranslate(List<String> lines, String target, _Job job) async {
    final chunks = _chunk(lines, _googleMaxChars, 1);
    final results = await Future.wait(
      chunks.map((c) => _withRetries(() => _googleAligned(c, target, job), job)),
    );
    if (job.cancelled || results.any((r) => r == null)) return null;

    // Si Google detectó que la mayor parte ya está en el idioma destino,
    // no hay nada que traducir.
    final base = target.split('-').first;
    final sameChunks = results.where((r) => r!.detected?.split('-').first == base).length;
    if (sameChunks * 2 > results.length) return const [];

    final out = [for (final r in results) ...r!.lines];
    return alignedTo(out, lines.length);
  }

  /// Traduce un bloque y se asegura de que vuelva con la misma cantidad de
  /// líneas. Si Google juntó o separó renglones, parte el bloque en dos
  /// mitades y prueba de nuevo (en vez de pedir cada línea por separado,
  /// todas a la vez, que era lo que saturaba a Google).
  Future<({List<String> lines, String? detected})?> _googleAligned(
      List<String> lines, String target, _Job job) async {
    if (job.cancelled) return null;
    const emptyMarker = '·';
    if (lines.every((l) => l.trim().isEmpty)) {
      return (lines: List.filled(lines.length, ''), detected: null);
    }
    final safe = lines.map((l) => l.trim().isEmpty ? emptyMarker : l).toList();
    final joined = await _googleRaw(safe.join('\n'), target);
    if (joined == null) return null;
    final parts = joined.text.split('\n');
    if (parts.length == lines.length) {
      return (
        lines: [
          for (var i = 0; i < parts.length; i++) lines[i].trim().isEmpty ? '' : parts[i].trim(),
        ],
        detected: joined.detected,
      );
    }
    if (lines.length == 1) {
      return (lines: [joined.text.replaceAll('\n', ' ').trim()], detected: joined.detected);
    }
    final mid = lines.length ~/ 2;
    final left = await _googleAligned(lines.sublist(0, mid), target, job);
    if (left == null) return null;
    final right = await _googleAligned(lines.sublist(mid), target, job);
    if (right == null) return null;
    return (lines: [...left.lines, ...right.lines], detected: joined.detected);
  }

  Future<({String text, String? detected})?> _googleRaw(String text, String target) =>
      _googleLimiter.run(() async {
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
          retries: 0, // los reintentos los maneja _withRetries (sabe si se canceló)
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
      });

  // ---------------- MyMemory (respaldo) ----------------

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
  /// palabras comunes de cada idioma (MyMemory no detecta el idioma solo).
  /// Un empate prefiere traducir: es menos molesto mostrar una traducción
  /// de más que no mostrar ninguna.
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
    return spanishScore > englishScore ? 'es' : 'en';
  }

  Future<List<String>?> _myMemoryTranslate(List<String> lines, String target, _Job job) async {
    final sourceLang = _guessSourceLanguage(lines.join(' '));
    if (sourceLang == target.split('-').first) return const [];

    // De a un bloque por vez: la cuota gratuita de MyMemory es chica y
    // pedir todo junto la agotaba enseguida.
    final out = <String>[];
    for (final chunk in _chunk(lines, _maxCharsPerRequest, 1)) {
      if (job.cancelled) return null;
      final r = await _withRetries(() => _myMemoryAligned(chunk, sourceLang, target, job), job);
      if (r == null) return null;
      out.addAll(r);
    }
    return alignedTo(out, lines.length);
  }

  /// Como [_googleAligned]: si MyMemory junta u omite saltos de línea, se
  /// parte el bloque en mitades.
  Future<List<String>?> _myMemoryAligned(
      List<String> lines, String sourceLang, String target, _Job job) async {
    if (job.cancelled) return null;
    if (lines.every((l) => l.trim().isEmpty)) return List.filled(lines.length, '');
    const emptyMarker = '·';
    final safe = lines.map((l) => l.trim().isEmpty ? emptyMarker : l).toList();
    final text = await _myMemoryRaw(safe.join('\n'), sourceLang, target);
    if (text == null) return null;
    final parts = text.split('\n');
    if (parts.length == lines.length) {
      return [
        for (var i = 0; i < parts.length; i++)
          lines[i].trim().isEmpty || parts[i].trim() == emptyMarker ? '' : parts[i],
      ];
    }
    if (lines.length == 1) return [text.replaceAll('\n', ' ')];
    final mid = lines.length ~/ 2;
    final left = await _myMemoryAligned(lines.sublist(0, mid), sourceLang, target, job);
    if (left == null) return null;
    final right = await _myMemoryAligned(lines.sublist(mid), sourceLang, target, job);
    if (right == null) return null;
    return [...left, ...right];
  }

  /// `null` = falló de verdad (red, cuota agotada, etc.).
  Future<String?> _myMemoryRaw(String text, String sourceLang, String target) =>
      _myMemoryLimiter.run(() async {
        final uri = Uri.https('api.mymemory.translated.net', '/get', {
          'q': text,
          'langpair': '$sourceLang|$target',
        });
        final response = await AppHttp.get(uri, timeout: const Duration(seconds: 12), retries: 0);
        if (response.statusCode != 200) return null;
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        // MyMemory devuelve responseStatus como número o como texto según
        // el caso, así que lo comparamos como string para cubrir ambos.
        if (json['responseStatus']?.toString() != '200') return null;
        final translated = json['responseData']?['translatedText'] as String? ?? '';
        // Cuando se acaba la cuota gratuita diaria, MyMemory NO devuelve un
        // error: responde 200 con un texto de advertencia. Es un fallo.
        if (_looksLikeQuotaWarning(translated)) return null;
        return translated;
      });

  bool _looksLikeQuotaWarning(String text) {
    final upper = text.toUpperCase();
    return upper.contains('MYMEMORY WARNING') ||
        upper.contains('QUOTA') ||
        upper.contains('IS AN INVALID') ||
        upper.contains('INVALID SOURCE LANGUAGE') ||
        upper.contains('AMOUNT OF WORDS TRANSLATED');
  }
}

/// Una actualización de [TranslationService.translateLive].
class TranslationUpdate {
  /// La traducción (vacía = ya está en el idioma elegido) o `null` si
  /// falló.
  final List<String>? lines;

  /// `false` mientras se espera una traducción mejor (la de la IA).
  final bool isFinal;
  final bool fromAi;

  const TranslationUpdate(this.lines, {required this.isFinal, this.fromAi = false});
}

/// Para dejar de esperar una traducción (por ejemplo, al cambiar de
/// canción). Si nadie más la está esperando, deja de mandar pedidos.
class TranslationCancelToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

class _Job {
  int waiters = 0;

  /// Nadie la espera más: no mandar más pedidos.
  bool cancelled = false;
  late final Future<List<String>?> future;
}

/// Deja correr como mucho [max] tareas a la vez; el resto espera su turno
/// en orden de llegada.
class _Limiter {
  final int max;
  int _running = 0;
  final Queue<Completer<void>> _queue = Queue();

  _Limiter(this.max);

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= max) {
      final turn = Completer<void>();
      _queue.add(turn);
      await turn.future; // el que termina nos pasa su lugar
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      if (_queue.isNotEmpty) {
        _queue.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// Caché de traducciones en disco.
abstract class TranslationDiskCache {
  Future<List<String>?> read(String key);
  Future<void> write(String key, List<String> lines);
}

/// Caché en memoria con la misma interfaz que la de disco (para tests).
class MemoryTranslationDiskCache implements TranslationDiskCache {
  final Map<String, List<String>> entries = {};
  int reads = 0;

  @override
  Future<List<String>?> read(String key) async {
    reads++;
    return entries[key];
  }

  @override
  Future<void> write(String key, List<String> lines) async => entries[key] = List.of(lines);
}

/// Un archivo JSON por traducción en la carpeta de soporte de la app.
/// Si hay demasiados, se borran los más viejos.
class FileTranslationDiskCache implements TranslationDiskCache {
  static const _maxFiles = 800;
  Future<Directory?>? _dir;

  Future<Directory?> _directory() => _dir ??= () async {
        try {
          final base = await getApplicationSupportDirectory();
          final dir = Directory('${base.path}/translation_cache');
          await dir.create(recursive: true);
          unawaited(_prune(dir));
          return dir;
        } catch (_) {
          return null; // sin disco (por ejemplo, en tests): solo memoria
        }
      }();

  Future<File?> _file(String key) async {
    final dir = await _directory();
    if (dir == null) return null;
    return File('${dir.path}/${sha1.convert(utf8.encode(key))}.json');
  }

  @override
  Future<List<String>?> read(String key) async {
    final file = await _file(key);
    if (file == null || !await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['key'] != key) return null;
    return (json['lines'] as List<dynamic>).map((e) => e as String).toList();
  }

  @override
  Future<void> write(String key, List<String> lines) async {
    final file = await _file(key);
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({'key': key, 'lines': lines}), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _prune(Directory dir) async {
    try {
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      if (files.length <= _maxFiles) return;
      final dated = [for (final f in files) (file: f, at: (await f.stat()).modified)]
        ..sort((a, b) => a.at.compareTo(b.at));
      for (final e in dated.take(files.length - (_maxFiles * 0.8).round())) {
        await e.file.delete().catchError((_) => e.file);
      }
    } catch (_) {}
  }
}
