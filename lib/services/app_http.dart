import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'error_log.dart';

/// Cliente HTTP único de la app: todos los servicios (LRCLIB, traductor,
/// iTunes, Spotify...) pasan por aquí. Reintenta solo los errores que vale
/// la pena reintentar (sin conexión momentánea, timeout, "demasiados
/// pedidos" o el servidor caído) con espera creciente, y anota en el
/// [ErrorLog] lo que falla del todo.
///
/// En los tests se reemplaza [client] por un `MockClient` con respuestas
/// simuladas.
class AppHttp {
  static http.Client client = http.Client();

  /// Espera base entre reintentos (en tests se pone en cero).
  static Duration retryDelay = const Duration(milliseconds: 500);

  static const userAgent = 'LyricsApp v1.0 (https://github.com/Toinco/letras)';

  static bool _retryableStatus(int code) =>
      code == 429 || code == 502 || code == 503 || code == 504;

  static Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    int retries = 2,
    String? tag,
  }) =>
      _send(() => client.get(uri, headers: headers), uri, timeout, retries, tag);

  static Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 15),
    int retries = 2,
    String? tag,
  }) =>
      _send(() => client.post(uri, headers: headers, body: body), uri, timeout, retries, tag);

  static Future<http.Response> _send(
    Future<http.Response> Function() request,
    Uri uri,
    Duration timeout,
    int retries,
    String? tag,
  ) async {
    final label = tag ?? uri.host;
    for (var attempt = 0;; attempt++) {
      try {
        final response = await request().timeout(timeout);
        if (_retryableStatus(response.statusCode) && attempt < retries) {
          await _wait(attempt, response);
          continue;
        }
        if (response.statusCode >= 500 || response.statusCode == 429) {
          ErrorLog.record('http:$label', 'HTTP ${response.statusCode} en ${uri.path}');
        }
        return response;
      } on SocketException catch (e, st) {
        if (attempt < retries) {
          await _wait(attempt, null);
          continue;
        }
        ErrorLog.record('http:$label', 'Sin conexión: ${e.message}', st);
        rethrow;
      } on TimeoutException catch (e, st) {
        if (attempt < retries) {
          await _wait(attempt, null);
          continue;
        }
        ErrorLog.record('http:$label', 'Timeout en ${uri.path}', st);
        rethrow;
      } on http.ClientException catch (e, st) {
        if (attempt < retries) {
          await _wait(attempt, null);
          continue;
        }
        ErrorLog.record('http:$label', e.message, st);
        rethrow;
      }
    }
  }

  static Future<void> _wait(int attempt, http.Response? response) {
    // Si el servidor dice cuánto esperar (Retry-After), le hacemos caso,
    // sin pasarnos de 5 segundos.
    final retryAfter = int.tryParse(response?.headers['retry-after'] ?? '');
    final ms = retryAfter != null
        ? math.min(retryAfter * 1000, 5000)
        : retryDelay.inMilliseconds * math.pow(2, attempt).toInt();
    return Future.delayed(Duration(milliseconds: ms));
  }
}
