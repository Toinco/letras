import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../models/song.dart';
import 'app_http.dart';

/// Lo que reconoció el micrófono: la canción y en qué momento de ella
/// estaba sonando, para poder sincronizar la letra.
class MicMatch {
  final Song song;

  /// Posición estimada de la canción en el instante [at].
  final Duration position;
  final DateTime at;

  const MicMatch({required this.song, required this.position, required this.at});

  Duration positionNow() => position + DateTime.now().difference(at);
}

/// Reconocimiento de canciones "tipo Shazam": graba unos segundos de audio
/// ambiente con el micrófono y lo manda al servicio AudD (https://audd.io)
/// para identificar título y artista.
///
/// Requiere que el usuario cargue su propio API token de AudD en Ajustes
/// (tienen un plan gratuito limitado). Sirve como respaldo para cuando la
/// detección automática por notificación no encuentra nada (por ejemplo,
/// música sonando desde un altavoz externo en vez de la app del teléfono).
class AudioRecognitionService {
  final AudioRecorder _recorder = AudioRecorder();

  Future<bool> hasMicrophonePermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Graba [duration] segundos de audio y los envía a AudD.
  /// Devuelve la canción reconocida, o `null` si no hubo coincidencia.
  Future<Song?> recognizeFromMicrophone({
    required String apiToken,
    Duration duration = const Duration(seconds: 8),
  }) async =>
      (await recognizeWithPosition(apiToken: apiToken, duration: duration))?.song;

  /// Igual que [recognizeFromMicrophone], pero también devuelve en qué
  /// momento de la canción estaba (AudD lo informa como "timecode").
  Future<MicMatch?> recognizeWithPosition({
    required String apiToken,
    Duration duration = const Duration(seconds: 8),
  }) async {
    if (apiToken.trim().isEmpty) {
      throw Exception('Falta configurar el API token de AudD en Ajustes.');
    }
    if (!await hasMicrophonePermission()) {
      final granted = await requestMicrophonePermission();
      if (!granted) {
        throw Exception('Permiso de micrófono denegado.');
      }
    }

    final tempDir = await getTemporaryDirectory();
    final filePath =
        '${tempDir.path}/recognize_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: filePath,
    );
    await Future.delayed(duration);
    final recordedPath = await _recorder.stop();
    final recordedAt = DateTime.now();

    if (recordedPath == null) {
      throw Exception('No se pudo grabar audio.');
    }

    return _sendToAudD(File(recordedPath), apiToken, duration, recordedAt);
  }

  /// Si ya se está grabando (por ejemplo, el modo continuo), lo frena.
  Future<void> cancel() async {
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  static Duration? _parseTimecode(String? tc) {
    if (tc == null) return null;
    final parts = tc.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return Duration(seconds: seconds);
  }

  Future<MicMatch?> _sendToAudD(
      File audioFile, String apiToken, Duration recorded, DateTime recordedAt) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.audd.io/'),
    );
    request.fields['api_token'] = apiToken;
    request.fields['return'] = 'apple_music,spotify';
    request.files.add(await http.MultipartFile.fromPath('file', audioFile.path));

    final streamedResponse = await AppHttp.client.send(request).timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamedResponse);

    // Limpieza del archivo temporal de audio.
    try {
      await audioFile.delete();
    } catch (_) {}

    if (response.statusCode != 200) {
      throw Exception('AudD respondió ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['status'] != 'success' || json['result'] == null) {
      return null;
    }

    final result = json['result'] as Map<String, dynamic>;
    // La duración viene en los datos de Spotify o Apple Music, si están.
    final spotifyMs = (result['spotify'] as Map<String, dynamic>?)?['duration_ms'] as num?;
    final appleMs = (result['apple_music'] as Map<String, dynamic>?)?['durationInMillis'] as num?;
    final durationMs = spotifyMs ?? appleMs;
    final song = Song(
      title: result['title'] as String? ?? '',
      artist: result['artist'] as String? ?? '',
      album: result['album'] as String?,
      durationSeconds: durationMs == null ? null : durationMs.toInt() ~/ 1000,
    );
    // El "timecode" es dónde arranca el pedazo grabado dentro de la
    // canción: al final de la grabación ya iba [recorded] más adelante.
    final tc = _parseTimecode(result['timecode'] as String?);
    return MicMatch(
      song: song,
      position: (tc ?? Duration.zero) + recorded,
      at: recordedAt,
    );
  }
}
