import 'package:flutter/services.dart';

import '../models/song.dart';
import '../utils/platform.dart';

/// Una canción de tu biblioteca de Apple Music que escuchaste.
class PlayedSong {
  final Song song;
  final int plays;
  final DateTime? lastPlayed;

  const PlayedSong(this.song, this.plays, this.lastPlayed);
}

/// Lo que escuchaste en Apple Music, según tu biblioteca de Música (la
/// Mac guarda cuántas veces sonó cada canción y cuándo fue la última).
class AppleMusicHistory {
  final List<PlayedSong> songs;

  const AppleMusicHistory(this.songs);

  static const _channel = MethodChannel('io.letras.app/now_playing');

  /// Solo en la Mac. Con [launch], abre Música de fondo si está cerrada;
  /// si no, con Música cerrada devuelve vacío.
  static Future<AppleMusicHistory> load({bool launch = false}) async {
    if (!isMac) return const AppleMusicHistory([]);
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('musicLibraryStats', {'launch': launch});
      final songs = <PlayedSong>[];
      for (final item in raw ?? const []) {
        if (item is! List || item.length < 6) continue;
        final ms = (item[4] as num?)?.toDouble() ?? 0;
        songs.add(PlayedSong(
          Song(
            title: item[0] as String? ?? '',
            artist: item[1] as String? ?? '',
            album: (item[2] as String?)?.isEmpty ?? true ? null : item[2] as String,
            durationSeconds: (item[5] as num?)?.round(),
          ),
          (item[3] as num?)?.toInt() ?? 0,
          ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms.round()) : null,
        ));
      }
      return AppleMusicHistory(songs.where((s) => s.song.title.isNotEmpty).toList());
    } catch (_) {
      return const AppleMusicHistory([]);
    }
  }

  bool get isEmpty => songs.isEmpty;

  int get totalPlays => songs.fold(0, (a, s) => a + s.plays);

  /// Tiempo escuchado (veces × duración de cada canción).
  Duration get listeningTime =>
      Duration(seconds: songs.fold(0, (a, s) => a + s.plays * (s.song.durationSeconds ?? 0)));

  List<PlayedSong> topSongs([int n = 25]) =>
      ([...songs]..sort((a, b) => b.plays.compareTo(a.plays))).take(n).toList();

  List<PlayedSong> recent([int n = 25]) => ([...songs.where((s) => s.lastPlayed != null)]
        ..sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!)))
      .take(n)
      .toList();

  /// Artistas por cantidad de reproducciones.
  List<({String artist, int plays})> topArtists([int n = 20]) {
    final byArtist = <String, ({String artist, int plays})>{};
    for (final s in songs) {
      final name = s.song.artist.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      final prev = byArtist[key];
      byArtist[key] = (artist: prev?.artist ?? name, plays: (prev?.plays ?? 0) + s.plays);
    }
    return (byArtist.values.toList()..sort((a, b) => b.plays.compareTo(a.plays))).take(n).toList();
  }
}
