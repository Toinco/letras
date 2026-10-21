import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lyrics_app/data/app_database.dart';
import 'package:lyrics_app/models/lyric_line.dart';
import 'package:lyrics_app/models/lyrics_result.dart';
import 'package:lyrics_app/models/song.dart';
import 'package:lyrics_app/services/backup_service.dart';
import 'package:lyrics_app/services/lyrics_storage_service.dart';
import 'package:lyrics_app/services/playlist_service.dart';
import 'package:lyrics_app/services/stats_service.dart';

/// Carpetas del teléfono simuladas con una carpeta temporal.
class _FakePaths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  final String root;
  _FakePaths(this.root);

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

LyricsResult _lyrics(String title, String artist, List<String> lines) => LyricsResult(
      song: Song(title: title, artist: artist),
      plainLyrics: lines.join('\n'),
      syncedLyrics: [
        for (var i = 0; i < lines.length; i++)
          LyricLine(timestamp: Duration(seconds: i * 3), text: lines[i]),
      ],
    );

void main() {
  late Directory tmp;

  setUpAll(() => sqfliteFfiInit());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('letras_test');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    AppDatabase.factoryOverride = databaseFactoryFfi;
    AppDatabase.pathOverride = inMemoryDatabasePath;
    await AppDatabase.closeForTests();
  });

  tearDown(() async {
    await AppDatabase.closeForTests();
    await tmp.delete(recursive: true);
  });

  test('migra las descargas viejas (JSON) a SQLite sin perder nada', () async {
    final dir = Directory('${tmp.path}/lyrics')..createSync();
    final a = _lyrics('Canción A', 'Artista', ['Hola', 'Chau']);
    final b = _lyrics('Song B', 'Band', ['Hello']);
    final keyA = LyricsStorageService.keyFor(a.song.title, a.song.artist);
    final keyB = LyricsStorageService.keyFor(b.song.title, b.song.artist);
    File('${dir.path}/$keyA.json').writeAsStringSync(jsonEncode(a.toJson()));
    File('${dir.path}/$keyA.txt').writeAsStringSync('txt');
    File('${dir.path}/$keyA.art').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/$keyB.json').writeAsStringSync(jsonEncode(b.toJson()));
    SharedPreferences.setMockInitialValues({
      'downloaded_songs_index': [keyA, keyB, 'falta_el_archivo'],
      'spotify_linked_songs': ['band|||song b'],
    });

    final storage = LyricsStorageService();
    final all = await storage.listAll();
    expect(all.map((r) => r.song.title), ['Canción A', 'Song B']); // mismo orden
    expect(await storage.isSaved('Canción A', 'Artista'), isTrue);
    expect((await storage.getSpotifyLinkedSongs()).single.title, 'Song B');
    // Los JSON viejos se borran, la carátula queda.
    expect(File('${dir.path}/$keyA.json').existsSync(), isFalse);
    expect(File('${dir.path}/$keyA.txt').existsSync(), isFalse);
    expect(await storage.getArtworkBytes('Canción A', 'Artista'), [1, 2, 3]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lyrics_migrated_to_sqlite'), isTrue);
    expect(prefs.getStringList('downloaded_songs_index'), isNull);
  });

  group('con la base vacía', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('guardar, re-guardar sin cambiar el orden, y borrar', () async {
      final storage = LyricsStorageService();
      await storage.save(_lyrics('Uno', 'X', ['a']));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await storage.save(_lyrics('Dos', 'X', ['b']));
      await storage.save(_lyrics('Uno', 'X', ['a corregida']));
      final all = await storage.listAll();
      expect(all.map((r) => r.song.title), ['Uno', 'Dos']);
      expect(all.first.plainLyrics, 'a corregida');
      await storage.remove('Uno', 'X');
      expect(await storage.count(), 1);
    });

    test('busca dentro de las letras e indica la línea', () async {
      final storage = LyricsStorageService();
      await storage.save(_lyrics('Corazón', 'Alguien', ['Primera', 'Te extraño mucho', 'Fin']));
      await storage.save(_lyrics('Otra', 'Nadie', ['Nada que ver']));
      final hits = await storage.searchInLyrics('extrano');
      expect(hits.length, 1);
      expect(hits.single.lineIndex, 1);
      expect(hits.single.lineText, 'Te extraño mucho');
      // Por título no marca línea.
      final byTitle = await storage.searchInLyrics('corazon');
      expect(byTitle.single.lineIndex, isNull);
      // Caracteres especiales de LIKE no rompen la búsqueda.
      expect(await storage.searchInLyrics('100%'), isEmpty);
    });

    test('playlists: agregar, ordenar y borrar la canción las saca', () async {
      final storage = LyricsStorageService();
      final a = _lyrics('A', 'X', ['a']);
      final b = _lyrics('B', 'X', ['b']);
      await storage.save(a);
      await storage.save(b);
      final playlists = PlaylistService();
      final id = await playlists.create('Para el auto');
      await playlists.add(id, a);
      await playlists.add(id, b);
      await playlists.add(id, a); // repetida: se ignora
      expect((await playlists.songs(id)).map((r) => r.song.title), ['A', 'B']);
      await playlists.reorder(id, [b, a]);
      expect((await playlists.songs(id)).map((r) => r.song.title), ['B', 'A']);
      expect((await playlists.list()).single.count, 2);
      await storage.remove('B', 'X');
      expect((await playlists.songs(id)).map((r) => r.song.title), ['A']);
    });

    test('estadísticas: más escuchadas y tiempo de letra', () async {
      final stats = StatsService();
      final p1 = await stats.startPlay('Hit', 'Star');
      await stats.startPlay('Hit', 'Star');
      final p3 = await stats.startPlay('Otra', 'Band');
      await stats.addLyricsTime(p1!, 120);
      await stats.addLyricsTime(p3!, 60);
      final s = await stats.load();
      expect(s.totalPlays, 3);
      expect(s.distinctSongs, 2);
      expect(s.lyricsTime, const Duration(minutes: 3));
      expect(s.topSongs.first.title, 'Hit');
      expect(s.topSongs.first.plays, 2);
      expect(s.topArtists.first.artist, 'Star');
    });

    test('copia de seguridad ZIP: ida y vuelta, sin duplicar', () async {
      final storage = LyricsStorageService();
      await storage.save(_lyrics('Guardada', 'Y', ['línea']));
      final playlists = PlaylistService();
      final id = await playlists.create('Favs');
      await playlists.add(id, (await storage.listAll()).single);
      await StatsService().startPlay('Guardada', 'Y');
      final zip = await BackupService().buildZip();

      // "Otro teléfono": base nueva.
      await AppDatabase.closeForTests();
      final summary = await BackupService().importZip(zip);
      expect(summary.lyricsAdded, 1);
      expect(summary.plays, 1);
      expect((await storage.listAll()).single.song.title, 'Guardada');
      expect((await PlaylistService().list()).single.name, 'Favs');

      // Importar de nuevo no duplica.
      final again = await BackupService().importZip(zip);
      expect(again.lyricsAdded, 0);
      expect((await StatsService().load()).totalPlays, 1);
      expect((await PlaylistService().list()).length, 1);
    });

    test('rechaza un ZIP que no es de la app', () async {
      expect(() => BackupService().importZip([1, 2, 3]), throwsFormatException);
    });
  });
}
