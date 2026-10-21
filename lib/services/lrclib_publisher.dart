import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../models/lyrics_result.dart';
import '../utils/lrc_parser.dart';
import 'app_http.dart';

/// Busca un nonce tal que SHA-256(prefix + nonce) <= target (comparando los
/// bytes como un número grande). Es la "prueba de trabajo" que pide LRCLIB
/// antes de aceptar una letra nueva, para frenar el spam. Función suelta
/// para poder correrla en otro isolate sin trabar la pantalla.
String solveChallenge(({String prefix, String target}) challenge) {
  final target = _hexToBytes(challenge.target);
  for (var nonce = 0;; nonce++) {
    final hash = sha256.convert(utf8.encode('${challenge.prefix}$nonce')).bytes;
    if (_lessOrEqual(hash, target)) return '$nonce';
  }
}

List<int> _hexToBytes(String hex) => [
      for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];

bool _lessOrEqual(List<int> hash, List<int> target) {
  for (var i = 0; i < hash.length && i < target.length; i++) {
    if (hash[i] < target[i]) return true;
    if (hash[i] > target[i]) return false;
  }
  return true;
}

/// Sube a LRCLIB una letra corregida o sincronizada a mano, para que le
/// sirva a todos los que usan LRCLIB.
class LrclibPublisher {
  static const _headers = {
    'User-Agent': AppHttp.userAgent,
    'Content-Type': 'application/json',
  };

  static const _channel = MethodChannel('io.letras.app/now_playing');

  /// En Android lo resuelve Kotlin (mucho más rápido); si no hay canal
  /// nativo, Dart en otro isolate.
  Future<String> _solve(String prefix, String target) async {
    try {
      final nonce = await _channel
          .invokeMethod<String>('solveLrclibChallenge', {'prefix': prefix, 'target': target});
      if (nonce != null) return nonce;
    } on MissingPluginException {
      // Tests / otra plataforma.
    } on PlatformException {
      // Sigue con Dart.
    }
    return Isolate.run(() => solveChallenge((prefix: prefix, target: target)));
  }

  /// Publica [lyrics]. LRCLIB exige título, artista, álbum y duración
  /// (con la duración distingue versiones de la misma canción). Tira una
  /// excepción con un mensaje entendible si algo falla.
  Future<void> publish(
    LyricsResult lyrics, {
    required String album,
    required int durationSeconds,
    void Function(String step)? onProgress,
  }) async {
    final song = lyrics.song;
    if (song.title.trim().isEmpty || song.artist.trim().isEmpty) {
      throw Exception('Falta el título o el artista.');
    }
    if (album.trim().isEmpty) throw Exception('Falta el nombre del álbum.');
    if (durationSeconds <= 0) throw Exception('Falta la duración de la canción.');

    onProgress?.call('Pidiendo permiso a LRCLIB...');
    final challengeResponse = await AppHttp.post(
      Uri.https('lrclib.net', '/api/request-challenge'),
      headers: _headers,
      tag: 'lrclib-publish',
    );
    if (challengeResponse.statusCode != 200) {
      throw Exception('LRCLIB no respondió (${challengeResponse.statusCode}).');
    }
    final challenge = jsonDecode(challengeResponse.body) as Map<String, dynamic>;
    final prefix = challenge['prefix'] as String;
    final target = challenge['target'] as String;

    onProgress?.call('Resolviendo la verificación anti-spam (puede tardar un minuto)...');
    final nonce = await _solve(prefix, target);

    onProgress?.call('Publicando...');
    final synced = lyrics.hasSyncedLyrics ? LrcParser.toLrc(lyrics.syncedLyrics) : null;
    final body = <String, dynamic>{
      'trackName': song.title.trim(),
      'artistName': song.artist.trim(),
      'albumName': album.trim(),
      'duration': durationSeconds,
      'plainLyrics': lyrics.plainLyrics,
      'syncedLyrics': synced,
    };
    if (lyrics.hasWordSync) {
      body['lyricsfile'] = LrcParser.toLyricsfile(
        title: song.title.trim(),
        artist: song.artist.trim(),
        album: album.trim(),
        durationMs: durationSeconds * 1000,
        lines: lyrics.syncedLyrics,
        plain: lyrics.plainLyrics,
      );
    }
    final response = await AppHttp.post(
      Uri.https('lrclib.net', '/api/publish'),
      headers: {..._headers, 'X-Publish-Token': '$prefix:$nonce'},
      body: jsonEncode(body),
      tag: 'lrclib-publish',
      retries: 0,
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception('LRCLIB rechazó la letra (${response.statusCode}): ${response.body}');
    }
  }
}
