import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/services/app_http.dart';
import 'package:lyrics_app/services/claude_translator.dart';
import 'package:lyrics_app/services/settings_service.dart';
import 'package:lyrics_app/services/translation_service.dart';
import 'package:lyrics_app/widgets/synced_lyrics_view.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// Respuesta de `translate_a/t`: traduce cada `q` agregándole " (en)".
http.Response _batchEcho(http.Request req, {String detected = 'es'}) {
  final qs = req.body.split('&').map((p) => Uri.decodeQueryComponent(p.substring(2))).toList();
  return _json([
    for (final q in qs) [q.isEmpty ? '' : '$q (en)', detected],
  ]);
}

/// Claude simulado: responde cuando se completa [reply].
class _FakeClaude extends ClaudeTranslator {
  final Completer<List<String>?> reply = Completer();
  int calls = 0;

  @override
  Future<List<String>?> translate(
    List<String> lines, {
    required String target,
    required String apiKey,
    String? title,
    String? artist,
  }) {
    calls++;
    return reply.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryTranslationDiskCache disk;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppHttp.retryDelay = Duration.zero;
    SettingsService.aiTranslation.value = false;
    SettingsService.translationLang.value = 'es';
    TranslationService.resetForTests();
    disk = MemoryTranslationDiskCache();
    TranslationService.defaultDiskCache = disk;
  });

  tearDown(() {
    AppHttp.client = http.Client();
    SettingsService.aiTranslation.value = false;
  });

  group('caché', () {
    test('la misma letra se pide una sola vez (memoria)', () async {
      var calls = 0;
      AppHttp.client = MockClient((req) async {
        calls++;
        return _batchEcho(req, detected: 'en');
      });
      final lines = ['Hello', 'world'];
      final a = await TranslationService().translate(lines);
      final b = await TranslationService().translate(lines);
      expect(a, ['Hello (en)', 'world (en)']);
      expect(b, a);
      expect(calls, 1);
    });

    test('se guarda en disco y se reutiliza aunque se borre la memoria', () async {
      var calls = 0;
      AppHttp.client = MockClient((req) async {
        calls++;
        return _batchEcho(req, detected: 'en');
      });
      final lines = ['Hello', 'world'];
      await TranslationService().translate(lines);
      expect(disk.entries, hasLength(1));

      TranslationService.resetForTests(); // como si se reiniciara la app
      final again = await TranslationService().translate(lines);
      expect(again, ['Hello (en)', 'world (en)']);
      expect(calls, 1);
    });

    test('dos pedidos simultáneos de la misma letra comparten uno solo', () async {
      var calls = 0;
      final release = Completer<void>();
      AppHttp.client = MockClient((req) async {
        calls++;
        await release.future;
        return _batchEcho(req, detected: 'en');
      });
      final lines = ['One', 'Two'];
      final a = TranslationService().translate(lines);
      final b = TranslationService().translate(lines);
      release.complete();
      expect(await a, await b);
      expect(calls, 1);
    });

    test('una canción larga va en lotes, no línea por línea', () async {
      var calls = 0;
      AppHttp.client = MockClient((req) async {
        calls++;
        return _batchEcho(req, detected: 'en');
      });
      final lines = [for (var i = 0; i < 300; i++) 'This is the line number $i of the song'];
      final out = await TranslationService().translate(lines);
      expect(out, hasLength(300));
      expect(out![123], 'This is the line number 123 of the song (en)');
      expect(calls, lessThanOrEqualTo(5));
    });

    test('un fallo no se guarda: el próximo intento vuelve a pedir', () async {
      var fail = true;
      AppHttp.client = MockClient((req) async {
        if (fail) return http.Response('caído', 503);
        return _batchEcho(req, detected: 'en');
      });
      final lines = ['Good night'];
      expect(await TranslationService().translate(lines), isNull);
      expect(disk.entries, isEmpty);
      fail = false;
      expect(await TranslationService().translate(lines), ['Good night (en)']);
    });

    test('si Google está saturado (429) reintenta y termina andando', () async {
      var calls = 0;
      AppHttp.client = MockClient((req) async {
        calls++;
        if (calls <= 3) return http.Response('Too many requests', 429);
        return _batchEcho(req, detected: 'en');
      });
      expect(await TranslationService().translate(['Hey']), ['Hey (en)']);
      expect(calls, 4);
    });

    test('ya en el idioma elegido: lista vacía; líneas sueltas en ese idioma quedan vacías',
        () async {
      AppHttp.client = MockClient((req) async => _batchEcho(req, detected: 'es'));
      expect(await TranslationService().translate(['Hola', 'che']), isEmpty);

      AppHttp.client = MockClient((req) async => _json([
            ['Te amo', 'en'],
            ['Mi corazón', 'es'],
            ['Para siempre', 'en'],
          ]));
      expect(
        await TranslationService().translate(['I love you', 'Mi corazón', 'Forever']),
        ['Te amo', '', 'Para siempre'],
      );
    });
  });

  group('cancelación', () {
    test('cancelar devuelve null al instante y no se manda nada más', () async {
      final requests = <String>[];
      final release = Completer<void>();
      AppHttp.client = MockClient((req) async {
        requests.add(req.url.path);
        await release.future;
        return http.Response('caído', 503); // si siguiera, reintentaría
      });
      final cancel = TranslationCancelToken();
      final future = TranslationService().translate(['Bye'], cancel: cancel);
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      expect(await future, isNull);

      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Solo el pedido que ya estaba en curso: sin reintentos ni respaldos.
      expect(requests, ['/translate_a/t']);
    });

    test('si otro sigue esperando la misma letra, cancelar no lo afecta', () async {
      final release = Completer<void>();
      AppHttp.client = MockClient((req) async {
        await release.future;
        return _batchEcho(req, detected: 'en');
      });
      final cancel = TranslationCancelToken();
      final cancelled = TranslationService().translate(['Stay'], cancel: cancel);
      final other = TranslationService().translate(['Stay']);
      cancel.cancel();
      release.complete();
      expect(await cancelled, isNull);
      expect(await other, ['Stay (en)']);
    });

    test('una traducción cancelada (canción vieja) no emite nada', () async {
      final release = Completer<void>();
      AppHttp.client = MockClient((req) async {
        await release.future;
        return _batchEcho(req, detected: 'en');
      });
      final cancel = TranslationCancelToken();
      final updates = <TranslationUpdate>[];
      final done =
          TranslationService().translateLive(['Old song'], cancel: cancel).forEach(updates.add);
      cancel.cancel(); // cambió la canción
      release.complete();
      await done;
      expect(updates, isEmpty);
    });
  });

  group('IA', () {
    test('primero muestra la automática y después la reemplaza la de la IA', () async {
      SharedPreferences.setMockInitialValues({'claude_api_key': 'k'});
      SettingsService.aiTranslation.value = true;
      AppHttp.client = MockClient((req) async => _batchEcho(req, detected: 'en'));
      final claude = _FakeClaude();
      final service = TranslationService(claude: claude);

      final updates = <TranslationUpdate>[];
      final done = service.translateLive(['Hello', 'world']).forEach(updates.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updates, hasLength(1));
      expect(updates.first.isFinal, isFalse);
      expect(updates.first.lines, ['Hello (en)', 'world (en)']);

      claude.reply.complete(['Hola', 'mundo']);
      await done;
      expect(updates.last.isFinal, isTrue);
      expect(updates.last.fromAi, isTrue);
      expect(updates.last.lines, ['Hola', 'mundo']);

      // La segunda vez sale de la caché, sin volver a llamar a la IA.
      final again = await service.translateLive(['Hello', 'world']).toList();
      expect(again.single.lines, ['Hola', 'mundo']);
      expect(claude.calls, 1);
    });

    test('si la IA falla, queda la automática y no se la reintenta enseguida', () async {
      SharedPreferences.setMockInitialValues({'claude_api_key': 'k'});
      SettingsService.aiTranslation.value = true;
      AppHttp.client = MockClient((req) async => _batchEcho(req, detected: 'en'));
      final claude = _FakeClaude()..reply.complete(null);
      final service = TranslationService(claude: claude);

      final first = await service.translateLive(['Night']).toList();
      expect(first.last.isFinal, isTrue);
      expect(first.last.lines, ['Night (en)']);

      await service.translateLive(['Day']).toList();
      expect(claude.calls, 1); // en pausa por un rato después del fallo
    });
  });

  group('sincronía', () {
    test('alignedTo solo acepta una traducción con una entrada por línea', () {
      expect(TranslationService.alignedTo(['a', 'b'], 2), ['a', 'b']);
      expect(TranslationService.alignedTo(const [], 2), isEmpty);
      expect(TranslationService.alignedTo(['a'], 2), isNull);
      expect(TranslationService.alignedTo(null, 2), isNull);
    });

    const lines = [
      LyricLine(timestamp: Duration(seconds: 1), text: 'Hello world'),
      LyricLine(timestamp: Duration(seconds: 5), text: 'Goodbye'),
      LyricLine(timestamp: Duration(seconds: 9), text: 'The end'),
    ];

    Future<StreamController<Duration>> pump(
      WidgetTester tester, {
      required List<String> translated,
    }) async {
      final position = StreamController<Duration>();
      addTearDown(position.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncedLyricsView(
            lines: lines,
            position: position.stream,
            translatedLines: translated,
            showTranslation: true,
            focusMode: true,
          ),
        ),
      ));
      return position;
    }

    testWidgets('cada traducción aparece con los tiempos de su línea original', (tester) async {
      final position = await pump(tester, translated: ['Hola mundo', 'Adiós', 'El fin']);

      position.add(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Hola mundo'), findsOneWidget);
      expect(find.text('Adiós'), findsNothing);

      position.add(const Duration(milliseconds: 5200));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Adiós'), findsOneWidget);
      expect(find.text('Hola mundo'), findsNothing);

      position.add(const Duration(milliseconds: 9300));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('El fin'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('una traducción con otra cantidad de líneas no se muestra (quedaría corrida)',
        (tester) async {
      final position = await pump(tester, translated: ['Adiós', 'El fin']);
      position.add(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Adiós'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
