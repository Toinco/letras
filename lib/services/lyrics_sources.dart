import 'dart:convert';

import 'package:html_unescape/html_unescape_small.dart';

import '../models/lyric_line.dart';
import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../utils/lrc_parser.dart';
import '../utils/text_normalize.dart';
import 'app_http.dart';

/// Fuentes de respaldo: si no contestan rápido, mejor seguir con otra.
const _timeout = Duration(seconds: 6);

const _browserUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile Safari/537.36';

/// ¿[candidateTitle]/[candidateArtist] parecen la canción buscada?
/// Puntaje: 0 = nada que ver; más alto = mejor.
int _similarity(String candidateTitle, String candidateArtist, String title, String artist) {
  final ct = normalizeForSearch(cleanTitleForMatching(candidateTitle));
  final qt = normalizeForSearch(cleanTitleForMatching(title));
  final ca = normalizeForSearch(candidateArtist);
  final qa = normalizeForSearch(primaryArtistName(artist));
  var score = 0;
  if (ct == qt) {
    score += 50;
  } else if (ct.isNotEmpty && qt.isNotEmpty && (ct.contains(qt) || qt.contains(ct))) {
    score += 25;
  } else {
    return 0;
  }
  if (qa.isNotEmpty && ca.contains(qa)) score += 30;
  return score;
}

/// Letras de NetEase Cloud Music (API pública no oficial): tiene mucho
/// catálogo asiático y en inglés, y muchas veces sincronización por
/// palabra (formato "yrc").
class NeteaseLyricsSource {
  static const _headers = {'Referer': 'https://music.163.com', 'User-Agent': _browserUa};

  Future<List<({int id, String title, String artist, int? durationMs})>> _search(
      String query) async {
    final uri = Uri.https('music.163.com', '/api/search/get', {
      's': query,
      'type': '1',
      'limit': '10',
    });
    final response = await AppHttp.get(uri,
        headers: _headers, tag: 'netease', timeout: _timeout, retries: 1);
    if (response.statusCode != 200) return [];
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final songs = (json['result']?['songs'] as List<dynamic>?) ?? [];
    return [
      for (final s in songs.whereType<Map<String, dynamic>>())
        (
          id: (s['id'] as num).toInt(),
          title: s['name'] as String? ?? '',
          artist: ((s['artists'] as List<dynamic>?) ?? [])
              .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
              .join(', '),
          durationMs: (s['duration'] as num?)?.toInt(),
        ),
    ];
  }

  Future<LyricsResult?> _lyricsFor(int id, Song song) async {
    final uri = Uri.https('music.163.com', '/api/song/lyric/v1', {
      'id': '$id',
      'lv': '-1',
      'yv': '-1',
      'tv': '-1',
    });
    final response = await AppHttp.get(uri,
        headers: _headers, tag: 'netease', timeout: _timeout, retries: 1);
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final yrc = json['yrc']?['lyric'] as String?;
    final lrc = json['lrc']?['lyric'] as String?;

    var lines = (yrc != null && yrc.trim().isNotEmpty) ? LrcParser.parseYrc(yrc) : <LyricLine>[];
    if (lines.isEmpty && lrc != null && lrc.trim().isNotEmpty) {
      lines = LrcParser.parse(lrc).where((l) => !LrcParser.isCreditLine(l.text)).toList();
    }
    if (lines.isEmpty) return null;
    final texts = lines.map((l) => l.text).where((t) => t.trim().isNotEmpty);
    // "纯音乐，请欣赏" = "instrumental, disfruta": sin letra de verdad.
    if (texts.length <= 2 && texts.any((t) => t.contains('纯音乐'))) return null;
    return LyricsResult(
      song: song,
      plainLyrics: texts.join('\n'),
      syncedLyrics: lines,
      source: LyricsSource.netease,
    );
  }

  /// Busca la canción y trae su letra sincronizada, o `null`.
  Future<LyricsResult?> find(String title, String artist, {int? durationSeconds}) async {
    final results = await _search('$title ${primaryArtistName(artist)}');
    final scored = <({int score, int id, Song song})>[];
    for (final r in results) {
      var score = _similarity(r.title, r.artist, title, artist);
      if (score == 0) continue;
      if (durationSeconds != null && durationSeconds > 0 && r.durationMs != null) {
        final diff = (r.durationMs! / 1000 - durationSeconds).abs();
        // Otra versión (en vivo, remix...) tiene otros tiempos: mejor nada.
        if (diff > 4) continue;
        score += diff <= 2 ? 10 : 5;
      }
      scored.add((
        score: score,
        id: r.id,
        song: Song(
          title: r.title,
          artist: r.artist,
          durationSeconds: r.durationMs == null ? null : r.durationMs! ~/ 1000,
        ),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    for (final c in scored.take(2)) {
      final lyrics = await _lyricsFor(c.id, c.song);
      if (lyrics != null) return lyrics;
    }
    return null;
  }
}

/// Letra plana (sin tiempos) de Genius, sacada de la página de la canción.
/// Es el último recurso: casi siempre la tiene, pero sin sincronizar.
class GeniusLyricsSource {
  static const _headers = {'User-Agent': _browserUa};

  Future<LyricsResult?> find(String title, String artist) async {
    final uri = Uri.https('genius.com', '/api/search/multi', {'q': '$title ${primaryArtistName(artist)}'});
    final response = await AppHttp.get(uri,
        headers: _headers, tag: 'genius', timeout: _timeout, retries: 1);
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final sections = (json['response']?['sections'] as List<dynamic>?) ?? [];
    ({int score, String url, Song song})? best;
    for (final section in sections.whereType<Map<String, dynamic>>()) {
      if (section['type'] != 'song') continue;
      for (final hit in (section['hits'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
        final r = hit['result'] as Map<String, dynamic>?;
        if (r == null) continue;
        final t = r['title'] as String? ?? '';
        final a = r['artist_names'] as String? ?? '';
        final score = _similarity(t, a, title, artist);
        if (score > (best?.score ?? 0)) {
          best = (score: score, url: r['url'] as String, song: Song(title: t, artist: a));
        }
      }
    }
    if (best == null) return null;
    final page = await AppHttp.get(Uri.parse(best.url),
        headers: _headers, tag: 'genius', timeout: _timeout, retries: 1);
    if (page.statusCode != 200) return null;
    final text = extractLyricsFromHtml(utf8.decode(page.bodyBytes));
    if (text.trim().isEmpty) return null;
    return LyricsResult(song: best.song, plainLyrics: text, source: LyricsSource.genius);
  }

  /// Saca la letra de la página de Genius: está repartida en varios
  /// `<div data-lyrics-container="true">`, con `<br>` entre renglones y
  /// un encabezado ("Translations", "Contributors"...) a descartar.
  static String extractLyricsFromHtml(String html) {
    final container = RegExp(r'<div[^>]*data-lyrics-container="true"[^>]*>');
    final excluded = RegExp(r'<div[^>]*data-exclude-from-selection="true"[^>]*>');
    final parts = <String>[];
    for (final m in container.allMatches(html)) {
      final end = _divEnd(html, m.start);
      var block = html.substring(m.end, end);
      while (true) {
        final e = excluded.firstMatch(block);
        if (e == null) break;
        block = block.substring(0, e.start) + block.substring(_divEnd(block, e.start));
      }
      block = block.replaceAll(RegExp(r'<br\s*/?>'), '\n').replaceAll(RegExp(r'<[^>]+>'), '');
      parts.add(HtmlUnescape().convert(block));
    }
    final lines = parts
        .join('\n')
        .split('\n')
        .map((l) => l.trim())
        // [Estribillo], [Verse 1: ...]: encabezados de sección, no letra.
        .where((l) => !RegExp(r'^\[.*\]$').hasMatch(l))
        .toList();
    // Sin más de una línea vacía seguida, ni vacías al principio/final.
    final out = <String>[];
    for (final l in lines) {
      if (l.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(l);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }

  /// Dónde termina el `<div>` que empieza en [start] (contando anidados).
  static int _divEnd(String s, int start) {
    var depth = 0;
    for (final m in RegExp(r'<(/?)div\b[^>]*>').allMatches(s, start)) {
      depth += m.group(1)!.isEmpty ? 1 : -1;
      if (depth == 0) return m.end;
    }
    return s.length;
  }
}
