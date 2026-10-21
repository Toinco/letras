import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';
import '../models/lyrics_result.dart';
import 'lyrics_storage_service.dart';

/// Una playlist de letras guardadas.
class LyricsPlaylist {
  final int id;
  final String name;
  final int count;

  const LyricsPlaylist({required this.id, required this.name, required this.count});
}

/// Playlists de letras descargadas ("Para cantar en el auto", "Inglés
/// para practicar"...). Viven en la misma base SQLite que las descargas.
class PlaylistService {
  /// Se incrementa con cada cambio, para refrescar las pantallas.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  Future<List<LyricsPlaylist>> list() async {
    final db = await AppDatabase.instance;
    final rows = await db.rawQuery(
      'SELECT p.id, p.name, COUNT(i.song_key) AS n FROM playlists p '
      'LEFT JOIN playlist_items i ON i.playlist_id = p.id '
      'GROUP BY p.id ORDER BY p.created_at DESC',
    );
    return [
      for (final r in rows)
        LyricsPlaylist(id: r['id'] as int, name: r['name'] as String, count: r['n'] as int),
    ];
  }

  Future<int> create(String name) async {
    final db = await AppDatabase.instance;
    final id = await db.insert('playlists', {
      'name': name.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    changes.value++;
    return id;
  }

  Future<void> rename(int id, String name) async {
    final db = await AppDatabase.instance;
    await db.update('playlists', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    changes.value++;
  }

  Future<void> delete(int id) async {
    final db = await AppDatabase.instance;
    await db.transaction((txn) async {
      await txn.delete('playlist_items', where: 'playlist_id = ?', whereArgs: [id]);
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
    });
    changes.value++;
  }

  Future<void> add(int playlistId, LyricsResult song) async {
    final db = await AppDatabase.instance;
    final key = LyricsStorageService.keyFor(song.song.title, song.song.artist);
    final next = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_items WHERE playlist_id = ?',
          [playlistId],
        )) ??
        0;
    await db.insert(
      'playlist_items',
      {'playlist_id': playlistId, 'song_key': key, 'position': next},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    changes.value++;
  }

  Future<void> remove(int playlistId, LyricsResult song) async {
    final db = await AppDatabase.instance;
    await db.delete(
      'playlist_items',
      where: 'playlist_id = ? AND song_key = ?',
      whereArgs: [playlistId, LyricsStorageService.keyFor(song.song.title, song.song.artist)],
    );
    changes.value++;
  }

  /// Ids de las playlists que ya tienen esta canción.
  Future<Set<int>> playlistsContaining(LyricsResult song) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'playlist_items',
      columns: ['playlist_id'],
      where: 'song_key = ?',
      whereArgs: [LyricsStorageService.keyFor(song.song.title, song.song.artist)],
    );
    return rows.map((r) => r['playlist_id'] as int).toSet();
  }

  /// Las letras de una playlist, en el orden en que se agregaron.
  Future<List<LyricsResult>> songs(int playlistId) async {
    final db = await AppDatabase.instance;
    final rows = await db.rawQuery(
      'SELECT l.json FROM playlist_items i JOIN lyrics l ON l.key = i.song_key '
      'WHERE i.playlist_id = ? ORDER BY i.position',
      [playlistId],
    );
    final storage = LyricsStorageService();
    final out = <LyricsResult>[];
    for (final r in rows) {
      final decoded = storage.decodeRow(r['json'] as String);
      if (decoded != null) out.add(decoded);
    }
    return out;
  }

  /// Mueve una canción dentro de la playlist (arrastrar para ordenar).
  Future<void> reorder(int playlistId, List<LyricsResult> ordered) async {
    final db = await AppDatabase.instance;
    final batch = db.batch();
    for (var i = 0; i < ordered.length; i++) {
      batch.update(
        'playlist_items',
        {'position': i},
        where: 'playlist_id = ? AND song_key = ?',
        whereArgs: [
          playlistId,
          LyricsStorageService.keyFor(ordered[i].song.title, ordered[i].song.artist),
        ],
      );
    }
    await batch.commit(noResult: true);
    changes.value++;
  }

  /// Para exportar/importar.
  Future<Map<String, dynamic>> exportData() async {
    final db = await AppDatabase.instance;
    return {
      'playlists': await db.query('playlists'),
      'items': await db.query('playlist_items'),
    };
  }

  Future<void> importData(Map<String, dynamic> data) async {
    final db = await AppDatabase.instance;
    final playlists = (data['playlists'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final items = (data['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    await db.transaction((txn) async {
      // Las ids pueden chocar con playlists que ya existen: se crean de
      // nuevo y se remapean (si ya hay una con el mismo nombre, se usa esa).
      final idMap = <int, int>{};
      for (final p in playlists) {
        final existing =
            await txn.query('playlists', where: 'name = ?', whereArgs: [p['name']], limit: 1);
        idMap[p['id'] as int] = existing.isNotEmpty
            ? existing.first['id'] as int
            : await txn.insert('playlists', {'name': p['name'], 'created_at': p['created_at']});
      }
      for (final i in items) {
        final newId = idMap[i['playlist_id'] as int];
        if (newId == null) continue;
        await txn.insert(
          'playlist_items',
          {'playlist_id': newId, 'song_key': i['song_key'], 'position': i['position']},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
    changes.value++;
  }
}
