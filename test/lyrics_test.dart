import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/utils/lrc_parser.dart';
import 'package:lyrics_app/widgets/synced_lyrics_view.dart';

void main() {
  group('LrcParser', () {
    test('parsea tiempos con 2 y 3 decimales, y varias marcas por línea', () {
      final lines = LrcParser.parse('[00:01.50]Hola\n[00:03.250][00:10.00]Estribillo\n[ar:Artista]');
      expect(lines.map((l) => l.text), ['Hola', 'Estribillo', 'Estribillo']);
      expect(lines[0].timestamp, const Duration(seconds: 1, milliseconds: 500));
      expect(lines[1].timestamp, const Duration(seconds: 3, milliseconds: 250));
      expect(lines[2].timestamp, const Duration(seconds: 10));
    });

    test('aplica [offset:] y saca las marcas por palabra', () {
      final lines = LrcParser.parse('[offset:+500]\n[00:02.00]<00:02.00>Una <00:02.50>línea');
      expect(lines.single.text, 'Una línea');
      expect(lines.single.timestamp, const Duration(milliseconds: 1500));
    });

    test('mantiene líneas vacías (instrumentales)', () {
      final lines = LrcParser.parse('[00:01.00]Algo\n[00:05.00]\n[00:09.00]Otra');
      expect(lines.length, 3);
      expect(lines[1].text, '');
    });
  });

  group('SyncedLyricsView', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    const lines = [
      LyricLine(timestamp: Duration(seconds: 1), text: 'Primera línea'),
      LyricLine(timestamp: Duration(seconds: 4), text: 'Segunda línea bastante larga que en un teléfono ocupa varios renglones sin cortarse'),
      LyricLine(timestamp: Duration(seconds: 8), text: ''),
      LyricLine(timestamp: Duration(seconds: 12), text: 'Tercera línea'),
    ];

    testWidgets('muestra líneas largas completas y permite tocar para saltar', (tester) async {
      final controller = StreamController<Duration>.broadcast();
      Duration? seekedTo;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncedLyricsView(
            lines: lines,
            position: controller.stream,
            onSeek: (d) => seekedTo = d,
          ),
        ),
      ));

      controller.add(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));

      // La línea larga ya no se corta con "...": se ve completa y ocupa
      // varios renglones.
      final longLine = find.textContaining('sin cortarse');
      expect(longLine, findsOneWidget);
      expect(tester.widget<Text>(longLine).overflow, isNot(TextOverflow.ellipsis));
      expect(tester.getSize(longLine).height, greaterThan(60));

      await tester.ensureVisible(find.text('Tercera línea'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Tercera línea'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(seekedTo, const Duration(seconds: 12));

      await controller.close();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('aplica el desfase al saltar', (tester) async {
      final controller = StreamController<Duration>.broadcast();
      Duration? seekedTo;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncedLyricsView(
            lines: lines,
            position: controller.stream,
            offset: const Duration(milliseconds: 500),
            onSeek: (d) => seekedTo = d,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Primera línea'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(seekedTo, const Duration(milliseconds: 500));
      await controller.close();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sin letra sincronizada muestra la letra plana', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SyncedLyricsView(
            lines: [],
            position: Stream.empty(),
            plainLyricsFallback: 'Letra plana\nSegunda',
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('Letra plana'), findsOneWidget);
      expect(find.text('Letra sin sincronizar'), findsOneWidget);
    });
  });

  group('Vista nueva', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    const wordLines = [
      LyricLine(
        timestamp: Duration(seconds: 1),
        text: 'Te quiero (te quiero)',
        words: [
          LyricWord(start: Duration(seconds: 1), end: Duration(seconds: 2), text: 'Te '),
          LyricWord(start: Duration(seconds: 2), end: Duration(seconds: 3), text: 'quiero '),
          LyricWord(start: Duration(seconds: 3), end: Duration(seconds: 4), text: '(te quiero)'),
        ],
      ),
      LyricLine(timestamp: Duration(seconds: 6), text: 'Segunda línea'),
      LyricLine(timestamp: Duration(seconds: 9), text: 'Tercera'),
    ];

    testWidgets('los coros se muestran aparte y el desenfoque no rompe nada', (tester) async {
      final controller = StreamController<Duration>.broadcast();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SyncedLyricsView(lines: wordLines, position: controller.stream)),
      ));
      controller.add(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      // La línea 1 ya no es la actual: se ve como texto, partida en voz y coro.
      expect(find.text('Te quiero'), findsOneWidget);
      expect(find.text('te quiero'), findsOneWidget);
      expect(find.byType(ImageFiltered), findsWidgets);
      await controller.close();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('modo karaoke muestra la actual grande y la siguiente', (tester) async {
      final controller = StreamController<Duration>.broadcast();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncedLyricsView(lines: wordLines, position: controller.stream, focusMode: true),
        ),
      ));
      controller.add(const Duration(seconds: 6, milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      // La siguiente se ve chiquita como texto; la actual se pinta con karaoke.
      expect(find.text('Tercera'), findsOneWidget);
      expect(find.text('Te quiero'), findsNothing);
      await controller.close();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
