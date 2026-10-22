import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/widgets/synced_lyrics_view.dart';

/// Los tres puntitos (el widget es privado: se busca por nombre).
final _dots = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_InterludeDots');

void main() {
  const lines = [
    LyricLine(
      timestamp: Duration(seconds: 1),
      end: Duration(seconds: 3),
      text: 'Hola mundo',
      words: [
        LyricWord(start: Duration(seconds: 1), end: Duration(seconds: 2), text: 'Hola '),
        LyricWord(start: Duration(seconds: 2), end: Duration(seconds: 3), text: 'mundo'),
      ],
    ),
    LyricLine(timestamp: Duration(seconds: 10), text: 'Chau'),
    LyricLine(timestamp: Duration(seconds: 12), text: 'Fin'),
  ];

  Future<StreamController<Duration>> pump(WidgetTester tester, {bool focus = false}) async {
    final position = StreamController<Duration>();
    addTearDown(position.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncedLyricsView(lines: lines, position: position.stream, focusMode: focus),
      ),
    ));
    return position;
  }

  testWidgets('en una pausa larga entre frases aparecen los puntitos', (tester) async {
    final position = await pump(tester);
    position.add(const Duration(milliseconds: 1500)); // cantando "Hola"
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_dots, findsNothing);

    position.add(const Duration(seconds: 5)); // ya terminó, falta para "Chau"
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dots, findsOneWidget);

    position.add(const Duration(seconds: 11)); // "Chau": se van
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dots, findsNothing);

    // Entre "Chau" y "Fin" hay 2 s: no es pausa.
    position.add(const Duration(milliseconds: 11900));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_dots, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('en el modo karaoke la pausa también muestra los puntitos', (tester) async {
    final position = await pump(tester, focus: true);
    position.add(const Duration(milliseconds: 2500));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400)); // termina la transición
    expect(find.byType(CustomPaint), findsWidgets);
    expect(_dots, findsNothing);

    position.add(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dots, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
