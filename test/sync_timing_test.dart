import 'package:flutter_test/flutter_test.dart';

import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/models/lyrics_result.dart';
import 'package:lyrics_app/models/song.dart';
import 'package:lyrics_app/services/lyrics_finder.dart';
import 'package:lyrics_app/services/now_playing_service.dart';

const _song = Song(title: 'Tema', artist: 'Artista');

LyricsResult _lines(List<int> startsMs, {bool words = false}) => LyricsResult(
      song: _song,
      plainLyrics: '',
      syncedLyrics: [
        for (var i = 0; i < startsMs.length; i++)
          LyricLine(
            timestamp: Duration(milliseconds: startsMs[i]),
            text: 'línea $i',
            words: words
                ? [
                    LyricWord(start: Duration(milliseconds: startsMs[i]), text: 'línea '),
                    LyricWord(start: Duration(milliseconds: startsMs[i] + 400), text: '$i'),
                  ]
                : const [],
          ),
      ],
    );

void main() {
  group('Alinear tiempos por palabra a LRCLIB', () {
    final lrclib = _lines([10000, 14000, 18000, 22000, 26000, 30000]);

    test('Una versión corrida 1 s se corrige en vez de usarse atrasada', () {
      final netease = _lines([11000, 15000, 19000, 23000, 27000, 31000], words: true);
      final aligned = LyricsFinder.alignWordSync(lrclib, netease)!;
      expect(aligned.syncedLyrics.map((l) => l.timestamp.inMilliseconds),
          [10000, 14000, 18000, 22000, 26000, 30000]);
      // Las palabras se corren igual.
      expect(aligned.syncedLyrics.first.words.last.start, const Duration(milliseconds: 10400));
    });

    test('Si ya coincide, se usa tal cual', () {
      final netease = _lines([10010, 14000, 17990, 22000, 26020, 30000], words: true);
      expect(identical(LyricsFinder.alignWordSync(lrclib, netease), netease), isTrue);
    });

    test('Otra versión (tiempos que no cuadran) se descarta', () {
      final netease = _lines([10000, 15200, 18100, 23400, 26000, 31300], words: true);
      expect(LyricsFinder.alignWordSync(lrclib, netease), isNull);
      expect(LyricsFinder.sameTiming(lrclib, netease), isFalse);
    });

    test('Sin tiempos por palabra no sirve', () {
      expect(LyricsFinder.alignWordSync(lrclib, _lines([10000, 14000, 18000, 22000])), isNull);
    });
  });

  group('Posición que llega del teléfono', () {
    test('Usa la hora en que Android midió la posición', () {
      final measured = DateTime.now().subtract(const Duration(milliseconds: 400));
      final t = NowPlayingTrack.fromMap({
        'title': 'Tema',
        'artist': 'Artista',
        'positionMs': 60000,
        'durationMs': 200000,
        'isPlaying': true,
        'capturedAtMs': measured.millisecondsSinceEpoch,
      });
      // Ya pasaron ~400 ms desde que se midió: la letra no arranca atrasada.
      expect(t.estimatedPositionNow().inMilliseconds, greaterThanOrEqualTo(60400));
    });

    test('Una hora rara (reloj cambiado) se ignora', () {
      final t = NowPlayingTrack.fromMap({
        'title': 'Tema',
        'artist': 'Artista',
        'positionMs': 60000,
        'durationMs': 200000,
        'isPlaying': true,
        'capturedAtMs': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      });
      expect(t.estimatedPositionNow().inMilliseconds, lessThan(60100));
    });

    test('Velocidad 0 estando en play no congela la letra', () {
      final t = NowPlayingTrack.fromMap({
        'title': 'Tema',
        'artist': 'Artista',
        'positionMs': 1000,
        'durationMs': 200000,
        'isPlaying': true,
        'playbackSpeed': 0.0,
      });
      expect(t.playbackSpeed, 1.0);
    });
  });
}
