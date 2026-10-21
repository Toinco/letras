import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// Historial de lo último que escuchaste / abriste (sin duplicados, lo más
/// reciente primero). Se muestra en Buscar para volver rápido a una letra.
class HistoryService {
  static const _key = 'listening_history';
  static const _maxEntries = 50;

  /// Notifica cada cambio, así la pantalla de Buscar se actualiza sola
  /// mientras suena música en "Reproduciendo".
  static final ValueNotifier<int> changes = ValueNotifier(0);

  String _id(Song s) => '${s.artist.toLowerCase().trim()}|||${s.title.toLowerCase().trim()}';

  Future<List<Song>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    final songs = <Song>[];
    for (final entry in raw) {
      try {
        songs.add(Song.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (_) {}
    }
    return songs;
  }

  Future<void> add(Song song) async {
    if (song.title.trim().isEmpty) return;
    final current = await list();
    final id = _id(song);
    // Si ya estaba, la movemos arriba conservando la carátula que tuviera.
    final previous = current.where((s) => _id(s) == id).firstOrNull;
    current.removeWhere((s) => _id(s) == id);
    final toStore = Song(
      title: song.title,
      artist: song.artist,
      album: song.album ?? previous?.album,
      durationSeconds: song.durationSeconds ?? previous?.durationSeconds,
      artworkUrl: song.artworkUrl ?? previous?.artworkUrl,
    );
    current.insert(0, toStore);
    if (current.length > _maxEntries) current.removeRange(_maxEntries, current.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, current.map((s) => jsonEncode(s.toJson())).toList());
    changes.value++;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    changes.value++;
  }
}
