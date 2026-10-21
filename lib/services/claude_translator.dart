import 'dart:convert';

import 'app_http.dart';
import 'error_log.dart';

/// Traducción de letras con Claude (API de Anthropic): entiende jerga,
/// dobles sentidos y referencias, cosa que un traductor automático no.
///
/// Dart no tiene SDK oficial de Anthropic, así que se llama a la API de
/// Messages por HTTP directo. La API key la carga el usuario en Ajustes y
/// queda solo en el teléfono. Cada traducción gasta créditos de esa
/// cuenta (una canción típica son unos pocos miles de tokens).
class ClaudeTranslator {
  static const _model = 'claude-opus-5-5';

  static const _languageNames = {
    'es': 'Spanish (neutral Latin American)',
    'en': 'English',
    'pt': 'Portuguese (Brazilian)',
    'fr': 'French',
    'it': 'Italian',
    'de': 'German',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh-CN': 'Simplified Chinese',
    'ru': 'Russian',
  };

  /// Devuelve la traducción alineada línea por línea, una lista vacía si
  /// la letra ya está en [target], o `null` si falló (sin key, sin
  /// crédito, sin conexión...). En ese caso se usa el traductor común.
  Future<List<String>?> translate(
    List<String> lines, {
    required String target,
    required String apiKey,
    String? title,
    String? artist,
  }) async {
    if (apiKey.trim().isEmpty || lines.isEmpty) return null;
    final language = _languageNames[target] ?? target;

    final prompt = StringBuffer()
      ..writeln('Translate these song lyrics into $language, line by line.')
      ..writeln()
      ..writeln(
          'They will be shown in a lyrics app, each translation directly under its original line, '
          'so the output must have exactly ${lines.length} entries in the same order as the input. '
          'Translate meaning, not word by word: carry slang, idioms, wordplay and double meanings '
          'over to natural equivalents a native speaker would use, and keep the tone (tender, '
          'crude, ironic...). Keep proper names, ad-libs like "yeah" or "oh", and lines that are '
          'only symbols or empty as they are. If a line is already in $language, repeat it '
          'unchanged.')
      ..writeln()
      ..writeln('Set "already_in_target" to true only if almost the whole song is already in '
          '$language.');
    if (title != null && title.isNotEmpty) {
      prompt
        ..writeln()
        ..writeln('Song: "$title"${artist == null || artist.isEmpty ? '' : ' by $artist'}');
    }
    prompt
      ..writeln()
      ..writeln('<lyrics>')
      ..writeln(jsonEncode(lines))
      ..writeln('</lyrics>');

    try {
      final response = await AppHttp.post(
        Uri.https('api.anthropic.com', '/v1/messages'),
        headers: {
          'content-type': 'application/json',
          'x-api-key': apiKey.trim(),
          'anthropic-version': '2023-06-01',
          // Si el filtro de seguridad rechaza la letra (pasa con algunas
          // muy explícitas), la API reintenta sola con otro modelo.
          'anthropic-beta': 'server-side-fallback-2026-07-01',
        },
        body: jsonEncode({
          'model': _model,
          'max_tokens': 16000,
          'fallbacks': 'default',
          'output_config': {
            'effort': 'medium',
            'format': {
              'type': 'json_schema',
              'schema': {
                'type': 'object',
                'properties': {
                  'already_in_target': {'type': 'boolean'},
                  'lines': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['already_in_target', 'lines'],
                'additionalProperties': false,
              },
            },
          },
          'messages': [
            {'role': 'user', 'content': prompt.toString()},
          ],
        }),
        timeout: const Duration(seconds: 90),
        retries: 1,
        tag: 'claude',
      );

      if (response.statusCode != 200) {
        ErrorLog.record('claude', 'HTTP ${response.statusCode}: ${_errorMessage(response.body)}');
        return null;
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (json['stop_reason'] == 'refusal' || json['stop_reason'] == 'max_tokens') {
        ErrorLog.record('claude', 'Sin traducción (stop_reason: ${json['stop_reason']})');
        return null;
      }
      // La respuesta puede traer bloques de razonamiento antes del texto.
      final text = (json['content'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String)
          .join();
      final result = jsonDecode(text) as Map<String, dynamic>;
      if (result['already_in_target'] == true) return const [];
      final translated = (result['lines'] as List<dynamic>).map((e) => e.toString()).toList();
      if (translated.length != lines.length) {
        ErrorLog.record('claude', 'Devolvió ${translated.length} líneas para ${lines.length}');
        return null;
      }
      return [
        for (var i = 0; i < lines.length; i++) lines[i].trim().isEmpty ? '' : translated[i],
      ];
    } catch (e, st) {
      ErrorLog.record('claude', e, st);
      return null;
    }
  }

  static String _errorMessage(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['error'] as Map<String, dynamic>?)?['message'] as String? ?? body;
    } catch (_) {
      return body.length > 200 ? body.substring(0, 200) : body;
    }
  }
}
