import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';
import '../models/lyrics_result.dart';
import '../utils/text_normalize.dart';
import 'error_log.dart';

/// Una línea que coincide con lo buscado dentro de una letra descargada.
class LyricsSearchHit {
  final LyricsResult result;

  /// Índice de la línea (en la letra sincronizada si hay; si no, en los
  /// renglones de la letra plana). `null` si coincidió el título/artista.
  final int? lineIndex;
  final String? lineText;

  const LyricsSearchHit(this.result, {this.lineIndex, this.lineText});
}

/// Guarda letras descargadas para poder verlas después sin conexión
/// ("Descargas").
///
/// Desde octubre de 2026 viven en una base SQLite (ver [AppDatabase]); la
/// primera vez que se abre esta versión, las descargas viejas (archivos
/// JSON + lista en SharedPreferences) se pasan solas a la base. Las
/// carátulas siguen siendo archivos (`.art`), que es lo más eficiente para
/// imágenes.
class LyricsStorageService {
  static const _legacyIndexKey = 'downloaded_songs_index';
  static const _legacySpotifyLinkedKey = 'spotify_linked_songs';
  static const _migratedKey = 'lyrics_migrated_to_sqlite';

  /// Se incrementa cada vez que se guarda o borra una letra, para que la
  /// pestaña Descargas se actualice sola.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<void>? _migration;

  static String keyFor(String title, String artist) =>
      '${artist.toLowerCase().trim()}__${title.toLowerCase().trim()}'
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_');

  String _keyFor(String title, String artist) => keyFor(title, artist);

  Future<Directory> _lyricsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/lyrics');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Database> _db() async {
    final db = await AppDatabase.instance;
    await (_migration ??= _migrateLegacy(db));
    return db;
  }

  /// Texto normalizado (sin acentos, minúsculas) para buscar.
  static String _searchText(LyricsResult r) => normalizeForSearch(
        [
          r.song.title,
          r.song.artist,
          r.plainLyrics,
          if (r.hasSyncedLyrics) r.syncedLyrics.map((l) => l.text).join('\n'),
        ].join('\n'),
      );

  /// Pasa las descargas del formato viejo (un .json por canción) a SQLite.
  Future<void> _migrateLegacy(Database db) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedKey) ?? false) return;
    final index = prefs.getStringList(_legacyIndexKey) ?? [];
    if (index.isEmpty) {
      await prefs.setBool(_migratedKey, true);
      return;
    }
    try {
      final dir = await _lyricsDir();
      final linked = (prefs.getStringList(_legacySpotifyLinkedKey) ?? []).toSet();
      final base = DateTime.now().millisecondsSinceEpoch - index.length;
      final migratedFiles = <File>[];
      await db.transaction((txn) async {
        for (var i = 0; i < index.length; i++) {
          final file = File('${dir.path}/${index[i]}.json');
          if (!await file.exists()) continue;
          try {
            final result = LyricsResult.fromJson(jsonDecode(await file.readAsString()));
            final linkId = '${result.song.artist.toLowerCase().trim()}|||'
                '${result.song.title.toLowerCase().trim()}';
            await txn.insert(
              'lyrics',
              _row(result, savedAt: base + i, spotifyLinked: linked.contains(linkId)),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            migratedFiles.add(file);
            final txt = File('${dir.path}/${index[i]}.txt');
            if (await txt.exists()) migratedFiles.add(txt);
          } catch (_) {
            // Archivo corrupto: se saltea (igual que antes al listar).
          }
        }
      });
      for (final f in migratedFiles) {
        try {
          await f.delete();
        } catch (_) {}
      }
      await prefs.remove(_legacyIndexKey);
      await prefs.remove(_legacySpotifyLinkedKey);
      await prefs.setBool(_migratedKey, true);
    } catch (e, st) {
      // Si algo falla, no marcamos la migración: se reintenta la próxima vez.
      ErrorLog.record('migración sqlite', e, st);
    }
  }

  Map<String, Object?> _row(LyricsResult r, {required int savedAt, bool spotifyLinked = false}) => {
        'key': _keyFor(r.song.title, r.song.artist),
        'title': r.song.title,
        'artist': r.song.artist,
        'search_text': _searchText(r),
        'json': jsonEncode(r.toJson()),
        'has_synced': r.hasSyncedLyrics ? 1 : 0,
        'spotify_linked': spotifyLinked ? 1 : 0,
        'saved_at': savedAt,
      };

  /// Guarda (o actualiza) la letra. Si se pasa [artworkBytes], también
  /// guarda la carátula como archivo local para verla sin conexión.
  Future<void> save(LyricsResult result, {Uint8List? artworkBytes}) async {
    final db = await _db();
    final key = _keyFor(result.song.title, result.song.artist);
    await db.transaction((txn) async {
      final existing = await txn.query('lyrics',
          columns: ['saved_at', 'spotify_linked'], where: 'key = ?', whereArgs: [key]);
      if (existing.isEmpty) {
        await txn.insert('lyrics', _row(result, savedAt: DateTime.now().millisecondsSinceEpoch));
      } else {
        // Re-guardar no cambia su lugar en Descargas ni el vínculo con Spotify.
        final row = _row(
          result,
          savedAt: existing.first['saved_at'] as int,
          spotifyLinked: existing.first['spotify_linked'] == 1,
        )..remove('key');
        await txn.update('lyrics', row, where: 'key = ?', whereArgs: [key]);
      }
    });

    if (artworkBytes != null && artworkBytes.isNotEmpty) {
      try {
        final dir = await _lyricsDir();
        await File('${dir.path}/$key.art').writeAsBytes(artworkBytes);
      } catch (_) {}
    }
    changes.value++;
  }

  /// Devuelve la carátula guardada localmente para esta canción, o `null`.
  Future<Uint8List?> getArtworkBytes(String title, String artist) async {
    try {
      final dir = await _lyricsDir();
      final file = File('${dir.path}/${_keyFor(title, artist)}.art');
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Guarda solo la carátula (para importar copias de seguridad).
  Future<void> saveArtwork(String key, Uint8List bytes) async {
    final dir = await _lyricsDir();
    await File('${dir.path}/$key.art').writeAsBytes(bytes);
  }

  Future<bool> isSaved(String title, String artist) async {
    final db = await _db();
    final rows = await db.query('lyrics',
        columns: ['key'], where: 'key = ?', whereArgs: [_keyFor(title, artist)], limit: 1);
    return rows.isNotEmpty;
  }

  /// Devuelve la letra ya descargada (con su traducción, si se guardó),
  /// o `null` si no está descargada.
  Future<LyricsResult?> getSaved(String title, String artist) => getByKey(_keyFor(title, artist));

  Future<LyricsResult?> getByKey(String key) async {
    final db = await _db();
    final rows = await db.query('lyrics', columns: ['json'], where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return _decode(rows.first['json'] as String);
  }

  LyricsResult? decodeRow(String json) => _decode(json);

  /// Todas las filas tal cual (para la copia de seguridad).
  Future<List<Map<String, Object?>>> exportRows() async {
    final db = await _db();
    return db.query('lyrics', columns: ['key', 'json', 'spotify_linked', 'saved_at']);
  }

  /// Restaura filas de una copia de seguridad. Las que ya existen se
  /// reemplazan solo si [overwrite]. Devuelve cuántas se agregaron.
  Future<int> importRows(List<Map<String, dynamic>> rows, {bool overwrite = false}) async {
    final db = await _db();
    var added = 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        final result = _decode(row['json'] as String);
        if (result == null) continue;
        final key = _keyFor(result.song.title, result.song.artist);
        final exists =
            (await txn.query('lyrics', columns: ['key'], where: 'key = ?', whereArgs: [key]))
                .isNotEmpty;
        if (exists && !overwrite) continue;
        await txn.insert(
          'lyrics',
          _row(
            result,
            savedAt: (row['saved_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
            spotifyLinked: row['spotify_linked'] == 1,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (!exists) added++;
      }
    });
    changes.value++;
    return added;
  }

  /// Rutas de las carátulas guardadas (clave -> archivo).
  Future<Map<String, File>> artworkFiles() async {
    try {
      final dir = await _lyricsDir();
      final out = <String, File>{};
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.art')) {
          final name = e.uri.pathSegments.last;
          out[name.substring(0, name.length - 4)] = e;
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  LyricsResult? _decode(String json) {
    try {
      return LyricsResult.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String title, String artist) async {
    final key = _keyFor(title, artist);
    final db = await _db();
    await db.delete('lyrics', where: 'key = ?', whereArgs: [key]);
    await db.delete('playlist_items', where: 'song_key = ?', whereArgs: [key]);
    try {
      final dir = await _lyricsDir();
      final art = File('${dir.path}/$key.art');
      if (await art.exists()) await art.delete();
    } catch (_) {}
    changes.value++;
  }

  /// Marca una canción como descargada "porque estaba en tus me gusta de
  /// Spotify". Al sincronizar, si más adelante deja de estar ahí, se borra
  /// sola (ver FavoritesSyncService).
  Future<void> markSpotifyLinked(String title, String artist) async {
    final db = await _db();
    await db.update('lyrics', {'spotify_linked': 1},
        where: 'key = ?', whereArgs: [_keyFor(title, artist)]);
  }

  Future<void> unmarkSpotifyLinked(String title, String artist) async {
    final db = await _db();
    await db.update('lyrics', {'spotify_linked': 0},
        where: 'key = ?', whereArgs: [_keyFor(title, artist)]);
  }

  /// Todas las canciones descargadas por venir de tus "me gusta" de
  /// Spotify, como pares (title, artist).
  Future<List<({String title, String artist})>> getSpotifyLinkedSongs() async {
    final db = await _db();
    final rows =
        await db.query('lyrics', columns: ['title', 'artist'], where: 'spotify_linked = 1');
    return [
      for (final r in rows) (title: r['title'] as String, artist: r['artist'] as String),
    ];
  }

  /// Busca por título, artista o contenido de la letra entre las
  /// canciones ya descargadas. A diferencia de LRCLIB, esto sí es una
  /// búsqueda real dentro del texto de la letra.
  Future<List<LyricsResult>> searchLocal(String query) async {
    return (await searchInLyrics(query)).map((h) => h.result).toList();
  }

  /// Igual que [searchLocal], pero dice en qué línea de cada letra está
  /// lo buscado (para abrirla con esa línea resaltada).
  Future<List<LyricsSearchHit>> searchInLyrics(String query) async {
    final q = normalizeForSearch(query);
    if (q.isEmpty) return [];
    final db = await _db();
    final escaped = q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final rows = await db.query(
      'lyrics',
      columns: ['json'],
      where: r"search_text LIKE ? ESCAPE '\'",
      whereArgs: ['%$escaped%'],
      orderBy: 'saved_at DESC',
    );
    final hits = <LyricsSearchHit>[];
    for (final row in rows) {
      final r = _decode(row['json'] as String);
      if (r == null) continue;
      final lines = r.displayLines;
      final idx = lines.indexWhere((l) => normalizeForSearch(l).contains(q));
      final titleMatch = normalizeForSearch(r.song.title).contains(q) ||
          normalizeForSearch(r.song.artist).contains(q);
      if (idx >= 0 && !titleMatch) {
        hits.add(LyricsSearchHit(r, lineIndex: idx, lineText: lines[idx]));
      } else {
        hits.add(LyricsSearchHit(r));
      }
    }
    return hits;
  }

  String _coreTitle(String title) {
    var t = normalizeForSearch(title);
    t = t.replaceAll(RegExp(r'\(.*?\)'), ''); // (remastered), (live), etc.
    t = t.replaceAll(RegExp(r'\[.*?\]'), '');
    t = t.split(RegExp(r' - ')).first; // "Canción - Remix" -> "Canción"
    return t.trim();
  }

  String _coreArtist(String artist) {
    final first = artist.split(RegExp(r'[,&]| feat\.?| ft\.?', caseSensitive: false)).first;
    return normalizeForSearch(first).trim();
  }

  /// Borra letras descargadas duplicadas (la misma canción guardada más de
  /// una vez, por ejemplo por variantes de título como "Remasterizado" o
  /// distintas versiones de artista), dejando solo una copia de cada una.
  /// Devuelve cuántas se borraron.
  Future<int> removeDuplicates() async {
    final all = await listAll();
    final groups = <String, List<LyricsResult>>{};
    for (final r in all) {
      final key = '${_coreTitle(r.song.title)}|||${_coreArtist(r.song.artist)}';
      groups.putIfAbsent(key, () => []).add(r);
    }

    var removed = 0;
    for (final group in groups.values) {
      if (group.length <= 1) continue;
      // Nos quedamos con la "más completa": con letra sincronizada, con
      // traducción ya guardada, y si empatan, la de texto más largo.
      group.sort((a, b) {
        final syncedCmp = (b.hasSyncedLyrics ? 1 : 0).compareTo(a.hasSyncedLyrics ? 1 : 0);
        if (syncedCmp != 0) return syncedCmp;
        final translatedCmp =
            ((b.translatedLines != null) ? 1 : 0).compareTo((a.translatedLines != null) ? 1 : 0);
        if (translatedCmp != 0) return translatedCmp;
        return b.plainLyrics.length.compareTo(a.plainLyrics.length);
      });
      for (final dup in group.skip(1)) {
        await remove(dup.song.title, dup.song.artist);
        removed++;
      }
    }
    return removed;
  }

  /// Todas las descargas, de la más vieja a la más nueva.
  Future<List<LyricsResult>> listAll() async {
    final db = await _db();
    final rows = await db.query('lyrics', columns: ['json'], orderBy: 'saved_at ASC');
    return rows.map((row) => _decode(row['json'] as String)).whereType<LyricsResult>().toList();
  }

  Future<int> count() async {
    final db = await _db();
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM lyrics')) ?? 0;
  }
}
