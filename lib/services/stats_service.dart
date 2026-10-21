import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';

/// Una canción en el ranking de las más escuchadas.
class TopSong {
  final String title;
  final String artist;
  final int plays;
  final int lyricsSeconds;

  const TopSong({
    required this.title,
    required this.artist,
    required this.plays,
    required this.lyricsSeconds,
  });
}

class ListeningStats {
  final int totalPlays;
  final int distinctSongs;
  final Duration lyricsTime;
  final List<TopSong> topSongs;
  final List<({String artist, int plays})> topArtists;

  const ListeningStats({
    required this.totalPlays,
    required this.distinctSongs,
    required this.lyricsTime,
    required this.topSongs,
    required this.topArtists,
  });
}

/// Estadísticas de escucha: cada canción que suena con letra cuenta como
/// una reproducción, y se va sumando el tiempo que estuvo la letra en
/// pantalla mientras sonaba.
class StatsService {
  static String songId(String title, String artist) =>
      '${artist.toLowerCase().trim()}|||${title.toLowerCase().trim()}';

  /// Registra que empezó a sonar una canción. Devuelve el id de la
  /// reproducción, para ir sumándole tiempo de letra.
  Future<int?> startPlay(String title, String artist) async {
    if (title.trim().isEmpty) return null;
    try {
      final db = await AppDatabase.instance;
      return await db.insert('plays', {
        'song_id': songId(title, artist),
        'title': title,
        'artist': artist,
        'started_at': DateTime.now().millisecondsSinceEpoch,
        'lyrics_seconds': 0,
      });
    } catch (_) {
      return null;
    }
  }

  /// Suma [seconds] de letra vista a la reproducción [playId].
  Future<void> addLyricsTime(int playId, int seconds) async {
    if (seconds <= 0) return;
    try {
      final db = await AppDatabase.instance;
      await db.rawUpdate(
        'UPDATE plays SET lyrics_seconds = lyrics_seconds + ? WHERE id = ?',
        [seconds, playId],
      );
    } catch (_) {}
  }

  /// Estadísticas desde [since] (todas si es null).
  Future<ListeningStats> load({DateTime? since, int top = 10}) async {
    final db = await AppDatabase.instance;
    final where = since == null ? '' : 'WHERE started_at >= ${since.millisecondsSinceEpoch}';
    final totals = await db.rawQuery(
      'SELECT COUNT(*) AS plays, COUNT(DISTINCT song_id) AS songs, '
      'COALESCE(SUM(lyrics_seconds), 0) AS secs FROM plays $where',
    );
    final songs = await db.rawQuery(
      'SELECT title, artist, COUNT(*) AS plays, SUM(lyrics_seconds) AS secs FROM plays $where '
      'GROUP BY song_id ORDER BY plays DESC, secs DESC LIMIT ?',
      [top],
    );
    final artists = await db.rawQuery(
      'SELECT artist, COUNT(*) AS plays FROM plays $where '
      'GROUP BY LOWER(artist) ORDER BY plays DESC LIMIT ?',
      [top],
    );
    final t = totals.first;
    return ListeningStats(
      totalPlays: (t['plays'] as int?) ?? 0,
      distinctSongs: (t['songs'] as int?) ?? 0,
      lyricsTime: Duration(seconds: (t['secs'] as int?) ?? 0),
      topSongs: [
        for (final r in songs)
          TopSong(
            title: r['title'] as String,
            artist: r['artist'] as String,
            plays: r['plays'] as int,
            lyricsSeconds: (r['secs'] as int?) ?? 0,
          ),
      ],
      topArtists: [
        for (final r in artists) (artist: r['artist'] as String, plays: r['plays'] as int),
      ],
    );
  }

  Future<void> clear() async {
    final db = await AppDatabase.instance;
    await db.delete('plays');
  }

  /// Para exportar/importar.
  Future<List<Map<String, Object?>>> exportRows() async {
    final db = await AppDatabase.instance;
    return db.query('plays');
  }

  /// Importa reproducciones de una copia de seguridad, salteando las que
  /// ya están (misma canción en el mismo instante), así importar dos veces
  /// no duplica nada.
  Future<void> importRows(List<Map<String, dynamic>> rows) async {
    final db = await AppDatabase.instance;
    final existing = {
      for (final r in await db.query('plays', columns: ['song_id', 'started_at']))
        '${r['song_id']}@${r['started_at']}',
    };
    final batch = db.batch();
    for (final r in rows) {
      if (!existing.add('${r['song_id']}@${r['started_at']}')) continue;
      batch.insert('plays', {
        'song_id': r['song_id'],
        'title': r['title'],
        'artist': r['artist'],
        'started_at': r['started_at'],
        'lyrics_seconds': r['lyrics_seconds'] ?? 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }
}
