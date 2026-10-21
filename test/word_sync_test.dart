import 'package:flutter_test/flutter_test.dart';

import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/models/lyrics_result.dart';
import 'package:lyrics_app/models/song.dart';
import 'package:lyrics_app/services/lrclib_service.dart';
import 'package:lyrics_app/utils/lrc_parser.dart';
import 'package:lyrics_app/utils/vocal_parts.dart';

const _ms = Duration(milliseconds: 1);

void main() {
  group('LRC mejorado (tiempos por palabra)', () {
    test('lee cada palabra con su inicio y el fin de la última', () {
      final line = LrcParser.parse('[00:12.00]<00:12.00>Te <00:12.40>quiero<00:13.10>').single;
      expect(line.text, 'Te quiero');
      expect(line.words.map((w) => w.text), ['Te ', 'quiero']);
      expect(line.words[0].start, _ms * 12000);
      expect(line.words[1].start, _ms * 12400);
      expect(line.words[1].end, _ms * 13100);
    });

    test('el texto antes de la primera marca arranca con la línea', () {
      final line = LrcParser.parse('[00:05.00]Hola <00:05.50>mundo').single;
      expect(line.words.map((w) => w.text), ['Hola ', 'mundo']);
      expect(line.words.first.start, _ms * 5000);
    });

    test('una línea común no trae palabras', () {
      expect(LrcParser.parse('[00:01.00]Sin palabras').single.hasWordSync, isFalse);
    });
  });

  group('Lyricsfile (YAML de LRCLIB)', () {
    const yaml = '''
version: '1.0'
metadata:
  title: 'Hello'
  artist: 'Someone'
lines:
  - text: 'Hello world'
    start_ms: 1200
    end_ms: 2800
    words:
      - text: 'Hello '
        start_ms: 1200
        end_ms: 1900
      - text: 'world'
        start_ms: 1900
        end_ms: 2800
  - text: 'Second'
    start_ms: 3000
plain: |
  Hello world
  Second
''';

    test('lee líneas y palabras', () {
      final lines = LrcParser.parseLyricsfile(yaml)!;
      expect(lines.length, 2);
      expect(lines[0].text, 'Hello world');
      expect(lines[0].end, _ms * 2800);
      expect(lines[0].words.length, 2);
      expect(lines[1].hasWordSync, isFalse);
    });

    test('rechaza versiones desconocidas', () {
      expect(LrcParser.parseLyricsfile(yaml.replaceFirst("'1.0'", "'2.0'")), isNull);
    });

    test('ida y vuelta: lo que escribimos se vuelve a leer igual', () {
      final lines = LrcParser.parseLyricsfile(yaml)!;
      final written = LrcParser.toLyricsfile(
        title: "It's",
        artist: 'A',
        lines: lines,
        plain: 'Hello world\nSecond',
      );
      final again = LrcParser.parseLyricsfile(written)!;
      expect(again.map((l) => l.text), ['Hello world', 'Second']);
      expect(again[0].words[1].start, _ms * 1900);
    });

    test('LRCLIB usa el lyricsfile cuando hasWordSync es true', () {
      final r = LrclibService.fromLrclibJson({
        'id': 7,
        'trackName': 'Hello',
        'artistName': 'Someone',
        'duration': 10,
        'plainLyrics': 'Hello world',
        'syncedLyrics': '[00:01.20]Hello world',
        'hasWordSync': true,
        'lyricsfile': yaml,
      });
      expect(r.hasWordSync, isTrue);
      expect(r.lrclibId, 7);
    });

    test('toLrc arma una línea por renglón con centésimas', () {
      final lrc = LrcParser.toLrc(const [
        LyricLine(timestamp: Duration(minutes: 1, seconds: 2, milliseconds: 345), text: 'Hola'),
      ]);
      expect(lrc, '[01:02.35]Hola');
    });
  });

  group('Coros entre paréntesis', () {
    LinePresentation present(String text) => presentLine(
          LyricLine(timestamp: Duration.zero, text: text),
          estimatedEnd: const Duration(seconds: 4),
        );

    test('separa voz principal y coro', () {
      final p = present('Te quiero (te quiero)');
      expect(p.main!.text, 'Te quiero');
      expect(p.background!.text, 'te quiero');
    });

    test('una línea toda entre paréntesis es solo coro', () {
      final p = present('(Oh, oh, oh)');
      expect(p.main, isNull);
      expect(p.background!.text, 'Oh, oh, oh');
    });

    test('sin paréntesis no hay coro', () {
      final p = present('Nada especial');
      expect(p.main!.text, 'Nada especial');
      expect(p.background, isNull);
    });

    test('se puede apagar', () {
      final p = presentLine(
        const LyricLine(timestamp: Duration.zero, text: 'A (b)'),
        estimatedEnd: const Duration(seconds: 1),
        splitBackground: false,
      );
      expect(p.main!.text, 'A (b)');
      expect(p.background, isNull);
    });

    test('con tiempos por palabra, cada parte se llena con los suyos', () {
      const line = LyricLine(
        timestamp: Duration.zero,
        text: 'Yo (eco)',
        words: [
          LyricWord(start: Duration.zero, end: Duration(seconds: 1), text: 'Yo '),
          LyricWord(start: Duration(seconds: 1), end: Duration(seconds: 2), text: '(eco)'),
        ],
      );
      final p = presentLine(line, estimatedEnd: const Duration(seconds: 3));
      expect(p.main!.filledChars(const Duration(milliseconds: 500)), closeTo(1.0, 0.2));
      expect(p.main!.filledChars(const Duration(seconds: 1)), 2);
      expect(p.background!.filledChars(const Duration(milliseconds: 500)), 0);
      expect(p.background!.filledChars(const Duration(milliseconds: 1500)), closeTo(1.5, 0.01));
    });

    test('sin tiempos por palabra el llenado se estima de forma pareja', () {
      final p = present('abcd efgh');
      expect(p.main!.filledChars(Duration.zero), 0);
      expect(p.main!.filledChars(const Duration(seconds: 4)), 9);
      expect(p.main!.filledChars(const Duration(seconds: 2)), inInclusiveRange(3, 6));
    });
  });

  group('Agrupar versiones de LRCLIB', () {
    LyricsResult r(String title, String artist, {bool synced = false}) => LyricsResult(
          song: Song(title: title, artist: artist),
          plainLyrics: 'x',
          syncedLyrics: synced ? const [LyricLine(timestamp: Duration.zero, text: 'x')] : const [],
        );

    test('junta la misma canción y elige la sincronizada', () {
      final groups = LrclibService.groupVersions([
        r('Blinding Lights', 'The Weeknd'),
        r('Blinding Lights', 'The Weeknd, Major Lazer', synced: true),
        r('Blinding Lights (Remastered)', 'The Weeknd'),
        r('Blinding Lights', 'Teddy Swims'),
      ]);
      expect(groups.length, 2);
      expect(groups.first.count, 3);
      expect(groups.first.best.hasSyncedLyrics, isTrue);
      expect(groups.last.best.song.artist, 'Teddy Swims');
    });
  });

  test('LyricsResult guarda y lee palabras, idioma y fuente', () {
    const original = LyricsResult(
      song: Song(title: 'T', artist: 'A'),
      plainLyrics: 'p',
      syncedLyrics: [
        LyricLine(
          timestamp: Duration(seconds: 1),
          text: 'Hi you',
          words: [
            LyricWord(start: Duration(seconds: 1), text: 'Hi '),
            LyricWord(start: Duration(seconds: 2), end: Duration(seconds: 3), text: 'you'),
          ],
        ),
      ],
      translatedLines: ['Hola tú'],
      translationLang: 'es',
      romanizedLines: ['hai yu'],
      source: LyricsSource.netease,
    );
    final back = LyricsResult.fromJson(original.toJson());
    expect(back.syncedLyrics.single.words.length, 2);
    expect(back.syncedLyrics.single.words[1].end, const Duration(seconds: 3));
    expect(back.translationLang, 'es');
    expect(back.romanizedLines, ['hai yu']);
    expect(back.source, LyricsSource.netease);
  });

  test('las descargas viejas sin idioma se toman como español', () {
    final old = LyricsResult.fromJson({
      'song': {'title': 'T', 'artist': 'A'},
      'plainLyrics': '',
      'syncedLyrics': [],
      'translatedLines': ['x'],
    });
    expect(old.translationLang, 'es');
    expect(old.source, LyricsSource.lrclib);
  });
}
