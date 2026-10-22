import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lyrics_app/models/lyrics_result.dart';
import 'package:lyrics_app/services/app_http.dart';
import 'package:lyrics_app/services/claude_translator.dart';
import 'package:lyrics_app/services/lrclib_publisher.dart';
import 'package:lyrics_app/services/lrclib_service.dart';
import 'package:lyrics_app/services/lyrics_finder.dart';
import 'package:lyrics_app/services/lyrics_sources.dart';
import 'package:lyrics_app/services/settings_service.dart';
import 'package:lyrics_app/services/translation_service.dart';
import 'package:lyrics_app/services/update_service.dart';
import 'package:lyrics_app/utils/lrc_parser.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _lrclibTrack({
  int id = 1,
  String title = 'Blinding Lights',
  String artist = 'The Weeknd',
  num duration = 200,
  String? synced = '[00:01.00]Yeah\n[00:05.00]I been tryna call',
  String plain = 'Yeah\nI been tryna call',
}) =>
    {
      'id': id,
      'trackName': title,
      'artistName': artist,
      'albumName': 'After Hours',
      'duration': duration,
      'instrumental': false,
      'hasWordSync': false,
      'plainLyrics': plain,
      'syncedLyrics': synced,
    };

void main() {
  // Para los canales nativos (sin Android responden "no implementado").
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppHttp.retryDelay = Duration.zero;
    LyricsFinder.clearCache();
    SettingsService.extraSources.value = true;
    SettingsService.aiTranslation.value = false;
    SettingsService.translationLang.value = 'es';
    TranslationService.resetForTests();
    TranslationService.defaultDiskCache = MemoryTranslationDiskCache();
  });

  tearDown(() => AppHttp.client = http.Client());

  group('AppHttp', () {
    test('reintenta un 429 y devuelve la respuesta buena', () async {
      var calls = 0;
      AppHttp.client = MockClient((_) async {
        calls++;
        return calls < 3 ? http.Response('lento', 429) : http.Response('ok', 200);
      });
      final r = await AppHttp.get(Uri.parse('https://x.test/a'));
      expect(r.body, 'ok');
      expect(calls, 3);
    });

    test('reintenta sin conexión y al final tira el error', () async {
      var calls = 0;
      AppHttp.client = MockClient((_) async {
        calls++;
        throw const SocketException('sin red');
      });
      await expectLater(AppHttp.get(Uri.parse('https://x.test/a'), retries: 1),
          throwsA(isA<SocketException>()));
      expect(calls, 2);
    });

    test('un 404 no se reintenta', () async {
      var calls = 0;
      AppHttp.client = MockClient((_) async {
        calls++;
        return http.Response('no', 404);
      });
      expect((await AppHttp.get(Uri.parse('https://x.test/a'))).statusCode, 404);
      expect(calls, 1);
    });
  });

  group('LRCLIB', () {
    test('elige la versión que coincide y no la de otro artista', () async {
      AppHttp.client = MockClient((req) async {
        if (req.url.path == '/api/get') return http.Response('{}', 404);
        return _json([
          _lrclibTrack(id: 1, artist: 'Teddy Swims', duration: 199),
          _lrclibTrack(id: 2, artist: 'The Weeknd', synced: null),
          _lrclibTrack(id: 3, artist: 'The Weeknd'),
        ]);
      });
      final best = await LrclibService().getBestMatch(
        trackName: 'Blinding Lights (Remastered)',
        artistName: 'The Weeknd',
        durationSeconds: 200,
      );
      expect(best!.lrclibId, 3);
      expect(best.hasSyncedLyrics, isTrue);
    });

    test('no espera la búsqueda lenta si la exacta ya coincide en todo', () async {
      AppHttp.client = MockClient((req) async {
        if (req.url.path == '/api/get') {
          return _json(_lrclibTrack(id: 7, title: 'Save Your Tears', duration: 215));
        }
        // La búsqueda amplia de LRCLIB a veces tarda varios segundos.
        await Future<void>.delayed(const Duration(seconds: 3));
        return _json(<Object>[]);
      });
      final watch = Stopwatch()..start();
      final best = await LrclibService().getBestMatch(
        trackName: 'Save Your Tears',
        artistName: 'The Weeknd',
        durationSeconds: 215,
      );
      expect(best!.lrclibId, 7);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('si nada se parece, devuelve null en vez de otra canción', () async {
      AppHttp.client = MockClient((req) async {
        if (req.url.path == '/api/get') return http.Response('{}', 404);
        return _json([_lrclibTrack(title: 'Otra Cosa', duration: 100)]);
      });
      final best = await LrclibService().getBestMatch(
        trackName: 'Canción Inventada XYZ',
        artistName: 'Nadie',
        durationSeconds: 200,
      );
      expect(best, isNull);
    });
  });

  group('LyricsFinder', () {
    test('si LRCLIB está saturado, no deja esperando: usa NetEase', () async {
      LyricsFinder.lrclibPatience = const Duration(milliseconds: 200);
      addTearDown(() => LyricsFinder.lrclibPatience = const Duration(milliseconds: 2500));
      AppHttp.client = MockClient((req) async {
        switch (req.url.host) {
          case 'lrclib.net':
            // Colgado (como cuando está saturado).
            await Future<void>.delayed(const Duration(seconds: 4));
            return http.Response('{}', 503);
          case 'music.163.com':
            if (req.url.path == '/api/search/get') {
              return _json({
                'result': {
                  'songs': [
                    {
                      'id': 5,
                      'name': 'Lenta',
                      'artists': [
                        {'name': 'Alguien'},
                      ],
                      'duration': 180000,
                    },
                  ],
                },
              });
            }
            return _json({
              'lrc': {'lyric': '[00:02.00]Uno\n[00:04.00]Dos'},
            });
        }
        return http.Response('', 404);
      });
      final watch = Stopwatch()..start();
      final r = await LyricsFinder().find('Lenta', 'Alguien', durationSeconds: 180);
      expect(r!.source, LyricsSource.netease);
      expect(r.syncedLyrics.map((l) => l.text), ['Uno', 'Dos']);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('si LRCLIB solo tiene letra plana, prueba NetEase sincronizada', () async {
      AppHttp.client = MockClient((req) async {
        switch (req.url.host) {
          case 'lrclib.net':
            if (req.url.path == '/api/get') return http.Response('{}', 404);
            return _json([_lrclibTrack(title: 'Solo Plana', synced: null)]);
          case 'music.163.com':
            if (req.url.path == '/api/search/get') {
              return _json({
                'result': {
                  'songs': [
                    {
                      'id': 99,
                      'name': 'Solo Plana',
                      'artists': [
                        {'name': 'The Weeknd'},
                      ],
                      'duration': 200500,
                    },
                  ],
                },
              });
            }
            return _json({
              'lrc': {'lyric': '[00:00.00] 作词 : Alguien\n[00:02.00]Primera\n[00:04.00]Segunda'},
              'yrc': {
                'lyric': '{"t":0,"c":[{"tx":"créditos"}]}\n'
                    '[2000,1500](2000,700,0)Pri(2700,800,0)mera\n'
                    '[4000,1000](4000,1000,0)Segunda',
              },
            });
        }
        return http.Response('', 404);
      });
      final r = await LyricsFinder().find('Solo Plana', 'The Weeknd', durationSeconds: 200);
      expect(r!.source, LyricsSource.netease);
      expect(r.syncedLyrics.map((l) => l.text), ['Primera', 'Segunda']);
      expect(r.hasWordSync, isTrue);
    });

    group('tiempos por palabra de NetEase cuando LRCLIB solo trae líneas', () {
      const lrc = '[00:01.00]Uno\n[00:03.00]Dos\n[00:05.00]Tres\n[00:07.00]Cuatro';
      MockClient client(String yrc) => MockClient((req) async {
            switch (req.url.host) {
              case 'lrclib.net':
                if (req.url.path == '/api/get') {
                  return _json(_lrclibTrack(title: 'Cuenta', synced: lrc));
                }
                return _json([_lrclibTrack(title: 'Cuenta', synced: lrc)]);
              case 'music.163.com':
                if (req.url.path == '/api/search/get') {
                  return _json({
                    'result': {
                      'songs': [
                        {
                          'id': 7,
                          'name': 'Cuenta',
                          'artists': [
                            {'name': 'The Weeknd'},
                          ],
                          'duration': 200000,
                        },
                      ],
                    },
                  });
                }
                return _json({
                  'yrc': {'lyric': yrc},
                });
            }
            return http.Response('', 404);
          });

      test('usa NetEase si es la misma versión', () async {
        AppHttp.client = client('[1100,900](1100,400,0)U(1500,500,0)no\n'
            '[3000,900](3000,900,0)Dos\n[5050,900](5050,900,0)Tres\n'
            '[7000,900](7000,900,0)Cuatro');
        final r = await LyricsFinder().find('Cuenta', 'The Weeknd', durationSeconds: 200);
        expect(r!.source, LyricsSource.netease);
        expect(r.hasWordSync, isTrue);
        expect(r.song.album, 'After Hours'); // los datos de la canción, de LRCLIB
      });

      test('se queda con LRCLIB si NetEase está corrida', () async {
        AppHttp.client = client('[9000,900](9000,900,0)Uno\n[12000,900](12000,900,0)Dos\n'
            '[15000,900](15000,900,0)Tres\n[18000,900](18000,900,0)Cuatro');
        final r = await LyricsFinder().find('Cuenta', 'The Weeknd', durationSeconds: 200);
        expect(r!.source, LyricsSource.lrclib);
      });
    });

    test('NetEase descarta otra versión con distinta duración', () async {
      AppHttp.client = MockClient((req) async => _json({
            'result': {
              'songs': [
                {
                  'id': 1,
                  'name': 'Song',
                  'artists': [
                    {'name': 'Band'},
                  ],
                  'duration': 260000,
                },
              ],
            },
          }));
      expect(await NeteaseLyricsSource().find('Song', 'Band', durationSeconds: 200), isNull);
    });

    test('sin conexión en ninguna fuente, tira error y no lo guarda como "no hay"', () async {
      var online = false;
      AppHttp.client = MockClient((req) async {
        if (!online) throw const SocketException('sin red');
        if (req.url.path == '/api/get') return _json(_lrclibTrack());
        return _json([_lrclibTrack()]);
      });
      await expectLater(LyricsFinder().find('Blinding Lights', 'The Weeknd'), throwsA(anything));
      online = true;
      final r = await LyricsFinder().find('Blinding Lights', 'The Weeknd');
      expect(r, isNotNull);
    });
  });

  test('Genius: saca la letra del HTML sin encabezados ni secciones', () {
    const html = '<div data-lyrics-container="true" class="x">'
        '<div data-exclude-from-selection="true"><span>Translations</span><div>x</div></div>'
        '[Verse 1]<br/>Hola &amp; chau<br><a href="#"><span>Segunda línea</span></a><br/><br/>'
        '</div><p>otra cosa</p><div data-lyrics-container="true">[Chorus]<br>Estribillo</div>';
    expect(GeniusLyricsSource.extractLyricsFromHtml(html), 'Hola & chau\nSegunda línea\n\nEstribillo');
  });

  test('NetEase yrc: líneas con tiempos por palabra y sin créditos', () {
    final lines = LrcParser.parseYrc(
      '[1000,2000](1000,500,0)Hola (1500,1500,0)mundo\n[3000,500](3000,500,0)作词 : Alguien',
    );
    expect(lines.single.text, 'Hola mundo');
    expect(lines.single.words.length, 2);
    expect(lines.single.end, const Duration(milliseconds: 3000));
  });

  group('Traducción', () {
    test('Google por lotes: una línea por q, alineadas, en un solo pedido', () async {
      final calls = <http.Request>[];
      AppHttp.client = MockClient((req) async {
        calls.add(req);
        return _json([
          ['Hello', 'es'],
          ['', 'es'],
          ['world', 'es'],
        ]);
      });
      final out = await TranslationService().translate(['Hola', '', 'mundo'], target: 'en');
      expect(out, ['Hello', '', 'world']);
      expect(calls, hasLength(1));
      expect(calls.single.url.path, '/translate_a/t');
      expect(calls.single.url.queryParameters['tl'], 'en');
      expect(calls.single.body, 'q=Hola&q=&q=mundo');
    });

    test('Google: si el pedido por lotes falla, usa el de respaldo', () async {
      Uri? called;
      AppHttp.client = MockClient((req) async {
        if (req.url.path == '/translate_a/t') return http.Response('no', 503);
        called = req.url;
        return _json([
          [
            ['Hello\n', 'Hola\n'],
            ['world', 'mundo'],
          ],
          null,
          'es',
        ]);
      });
      final out = await TranslationService().translate(['Hola', 'mundo'], target: 'en');
      expect(out, ['Hello', 'world']);
      expect(called!.queryParameters['tl'], 'en');
    });

    test('si ya está en el idioma destino, devuelve lista vacía', () async {
      AppHttp.client = MockClient((_) async => _json([
            [
              ['Hola\n', 'Hola\n'],
              ['che', 'che'],
            ],
            null,
            'es',
          ]));
      expect(await TranslationService().translate(['Hola', 'che'], target: 'es'), isEmpty);
    });

    test('pronunciación: separa por ¶ y deja vacías las líneas latinas', () async {
      AppHttp.client = MockClient((req) async => _json([
            [
              [null, null, null, 'kimi no na wa ¶ - ¶ hoshi ga furu yoru ¶ yeah'],
            ],
            null,
            'ja',
          ]));
      final out = await TranslationService().romanize(['君の名は', '', '星が降る夜', 'yeah']);
      expect(out, ['kimi no na wa', '', 'hoshi ga furu yoru', '']);
    });
  });

  group('Claude', () {
    test('arma el pedido y lee el JSON alineado', () async {
      late Map<String, dynamic> sent;
      late Map<String, String> headers;
      AppHttp.client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        headers = req.headers;
        return _json({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'thinking', 'thinking': ''},
            {
              'type': 'text',
              'text': jsonEncode({
                'already_in_target': false,
                'lines': ['Te extraño, bebé', 'no traducir', ''],
              }),
            },
          ],
        });
      });
      final out = await ClaudeTranslator().translate(
        ['I miss you, baby', '', ''],
        target: 'es',
        apiKey: 'sk-test',
      );
      // Las líneas vacías del original quedan vacías.
      expect(out, ['Te extraño, bebé', '', '']);
      expect(headers['x-api-key'], 'sk-test');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(sent['model'], 'claude-opus-5-5');
      expect(sent['output_config']['format']['type'], 'json_schema');
      expect(sent.containsKey('temperature'), isFalse);
    });

    test('si devuelve otra cantidad de líneas, falla (y se usa el traductor común)', () async {
      AppHttp.client = MockClient((_) async => _json({
            'stop_reason': 'end_turn',
            'content': [
              {
                'type': 'text',
                'text': jsonEncode({'already_in_target': false, 'lines': ['una']}),
              },
            ],
          }));
      expect(
        await ClaudeTranslator().translate(['a', 'b'], target: 'es', apiKey: 'k'),
        isNull,
      );
    });

    test('un rechazo no rompe nada', () async {
      AppHttp.client =
          MockClient((_) async => _json({'stop_reason': 'refusal', 'content': <dynamic>[]}));
      expect(await ClaudeTranslator().translate(['x'], target: 'es', apiKey: 'k'), isNull);
    });
  });

  group('Publicar en LRCLIB', () {
    test('la prueba de trabajo encuentra un nonce válido', () {
      final nonce = solveChallenge((prefix: 'abc', target: '0FFF${'F' * 60}'));
      expect(int.parse(nonce), greaterThanOrEqualTo(0));
    });

    test('pide el desafío, lo resuelve y publica con el token', () async {
      final requests = <http.Request>[];
      AppHttp.client = MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/api/request-challenge') {
          return _json({'prefix': 'pre', 'target': '0FFF${'F' * 60}'});
        }
        return http.Response('', 201);
      });
      await LrclibPublisher().publish(
        LyricsResult.fromJson({
          'song': {'title': 'Tema', 'artist': 'Yo'},
          'plainLyrics': 'Hola',
          'syncedLyrics': [
            {'ms': 1000, 'text': 'Hola'},
          ],
        }),
        album: 'Disco',
        durationSeconds: 180,
      );
      final publish = requests.last;
      expect(publish.url.path, '/api/publish');
      expect(publish.headers['X-Publish-Token'], startsWith('pre:'));
      final body = jsonDecode(publish.body) as Map<String, dynamic>;
      expect(body['syncedLyrics'], '[00:01.00]Hola');
      expect(body['albumName'], 'Disco');
      expect(body['duration'], 180);
    });

    test('sin álbum no publica', () async {
      expect(
        () => LrclibPublisher().publish(
          LyricsResult.fromJson({
            'song': {'title': 'T', 'artist': 'A'},
            'plainLyrics': 'x',
          }),
          album: ' ',
          durationSeconds: 100,
        ),
        throwsException,
      );
    });
  });

  test('comparación de versiones para las actualizaciones', () {
    expect(UpdateService.compareVersions('v1.10.0', '1.9.3'), greaterThan(0));
    expect(UpdateService.compareVersions('1.2.0+5', '1.2.0'), 0);
    expect(UpdateService.compareVersions('1.2', '1.2.1'), lessThan(0));
  });
}
