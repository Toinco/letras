import 'package:yaml/yaml.dart';

import '../models/lyric_line.dart';

/// Convierte un texto en formato LRC (ej: "[00:12.34]Te quiero") en una
/// lista ordenada de [LyricLine], lista para animar en pantalla.
///
/// Soporta líneas con varias marcas de tiempo, como:
/// "[00:12.34][00:45.10]Estribillo", y el "LRC mejorado" con tiempos por
/// palabra: "[00:12.00]<00:12.00>Te <00:12.40>quiero<00:13.10>".
class LrcParser {
  // Ej: [00:12.34] o [00:12.340] o [01:02:03.45] (raro, pero por las dudas)
  static final RegExp _timeTag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _offsetTag = RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);
  // Marcas de tiempo por palabra del formato "LRC mejorado" (<00:12.34>).
  static final RegExp _wordTag = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>');

  static Duration _toDuration(String min, String sec, String? fraction) {
    var ms = 0;
    if (fraction != null) {
      // Normaliza a 3 dígitos ("34" -> 340, "340" -> 340)
      ms = int.parse(fraction.padRight(3, '0').substring(0, 3));
    }
    return Duration(minutes: int.parse(min), seconds: int.parse(sec), milliseconds: ms);
  }

  static List<LyricLine> parse(String lrcContent) {
    final lines = <LyricLine>[];
    // [offset:+500] = la letra entera hay que adelantarla medio segundo.
    var offsetMs = 0;

    for (final rawLine in lrcContent.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;

      final offsetMatch = _offsetTag.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        continue;
      }

      final matches = _timeTag.allMatches(line).toList();
      if (matches.isEmpty) continue; // línea de metadata ([ar:...], [ti:...], etc.)

      final body = line.substring(matches.last.end);
      final text = body.replaceAll(_wordTag, '').trim();

      for (final m in matches) {
        final start = _toDuration(m.group(1)!, m.group(2)!, m.group(3));
        lines.add(LyricLine(
          timestamp: start,
          text: text,
          words: _parseWords(body, start),
        ));
      }
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (offsetMs == 0) return lines;
    // En LRC, un offset positivo significa que la letra aparece ANTES.
    return [for (final l in lines) l.shifted(Duration(milliseconds: -offsetMs))];
  }

  /// Saca los tiempos por palabra de una línea de LRC mejorado. Cada
  /// `<mm:ss.xx>` marca dónde empieza el texto que lo sigue; una marca al
  /// final, sin texto después, es el fin de la última palabra.
  static List<LyricWord> _parseWords(String body, Duration lineStart) {
    final tags = _wordTag.allMatches(body).toList();
    if (tags.isEmpty) return const [];

    final words = <LyricWord>[];
    // Texto antes de la primera marca: arranca con la línea.
    final leading = body.substring(0, tags.first.start);
    if (leading.trim().isNotEmpty) {
      words.add(LyricWord(start: lineStart, text: leading.trimLeft()));
    }
    for (var i = 0; i < tags.length; i++) {
      final t = tags[i];
      final start = _toDuration(t.group(1)!, t.group(2)!, t.group(3));
      final textEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
      final text = body.substring(t.end, textEnd);
      if (text.isEmpty) {
        // Marca de cierre: es el fin de la palabra anterior.
        if (words.isNotEmpty && words.last.end == null) {
          words[words.length - 1] =
              LyricWord(start: words.last.start, end: start, text: words.last.text);
        }
        continue;
      }
      words.add(LyricWord(start: start, text: words.isEmpty ? text.trimLeft() : text));
    }
    if (words.isNotEmpty) {
      final last = words.last;
      words[words.length - 1] =
          LyricWord(start: last.start, end: last.end, text: last.text.trimRight());
    }
    return words;
  }

  /// Lee el formato "Lyricsfile" (YAML) que usa LRCLIB para las letras
  /// sincronizadas por palabra. Devuelve `null` si no se puede leer o no
  /// trae líneas sincronizadas.
  static List<LyricLine>? parseLyricsfile(String yamlContent) {
    try {
      final doc = loadYaml(yamlContent);
      if (doc is! YamlMap || doc['version']?.toString() != '1.0') return null;
      final rawLines = doc['lines'];
      if (rawLines is! YamlList || rawLines.isEmpty) return null;

      Duration? ms(dynamic v) => v is int ? Duration(milliseconds: v) : null;

      final lines = <LyricLine>[];
      for (final raw in rawLines) {
        if (raw is! YamlMap) continue;
        final start = ms(raw['start_ms']);
        if (start == null) continue;
        final words = <LyricWord>[];
        final rawWords = raw['words'];
        if (rawWords is YamlList) {
          for (final w in rawWords) {
            if (w is! YamlMap) continue;
            final ws = ms(w['start_ms']);
            if (ws == null) continue;
            words
                .add(LyricWord(start: ws, end: ms(w['end_ms']), text: w['text']?.toString() ?? ''));
          }
        }
        final text = raw['text']?.toString() ?? words.map((w) => w.text).join();
        lines.add(LyricLine(
          timestamp: start,
          text: text.trim(),
          end: ms(raw['end_ms']),
          words: words,
        ));
      }
      lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return lines.isEmpty ? null : lines;
    } catch (_) {
      return null;
    }
  }

  // Créditos que NetEase mete como si fueran líneas de la letra
  // ("作词 : Fulano", "Producer: ...").
  static final RegExp _creditLine = RegExp(
    r'^\s*(作词|作曲|编曲|制作人|制作|混音|母带|和声|吉他|贝斯|鼓|录音|监制|出品|词|曲|'
    r'producer|produced by|lyricist|lyrics by|composer|composed by|arranger|written by)\s*[:：]',
    caseSensitive: false,
  );

  static bool isCreditLine(String text) => _creditLine.hasMatch(text);

  /// Lee el formato "yrc" de NetEase, con tiempos por palabra:
  /// `[27360,1290](27360,240,0)I've (27600,90,0)been ...`
  /// (inicio y duración de la línea, y de cada palabra, en ms).
  static List<LyricLine> parseYrc(String content) {
    final lineTag = RegExp(r'^\[(\d+),(\d+)\]');
    final wordTag = RegExp(r'\((\d+),(\d+),\d+\)');
    final lines = <LyricLine>[];
    for (final raw in content.split('\n')) {
      final m = lineTag.firstMatch(raw.trim());
      if (m == null) continue; // líneas JSON de créditos, etc.
      final start = Duration(milliseconds: int.parse(m.group(1)!));
      final end = start + Duration(milliseconds: int.parse(m.group(2)!));
      final body = raw.trim().substring(m.end);
      final tags = wordTag.allMatches(body).toList();
      final words = <LyricWord>[];
      for (var i = 0; i < tags.length; i++) {
        final t = tags[i];
        final textEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
        final text = body.substring(t.end, textEnd);
        if (text.isEmpty) continue;
        final ws = Duration(milliseconds: int.parse(t.group(1)!));
        words.add(LyricWord(
          start: ws,
          end: ws + Duration(milliseconds: int.parse(t.group(2)!)),
          text: text,
        ));
      }
      final text = (tags.isEmpty ? body : words.map((w) => w.text).join()).trim();
      if (isCreditLine(text)) continue;
      lines.add(LyricLine(timestamp: start, end: end, text: text, words: words));
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  // ------------------------------------------------------------ escritura

  static String _fmt(Duration d) {
    final totalCs = (d.inMilliseconds / 10).round();
    final min = totalCs ~/ 6000;
    final sec = (totalCs % 6000) ~/ 100;
    final cs = totalCs % 100;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}';
  }

  /// Arma el texto LRC (una línea por renglón) a partir de las líneas.
  static String toLrc(List<LyricLine> lines) =>
      lines.map((l) => '[${_fmt(l.timestamp)}]${l.text}').join('\n');

  static String _yamlString(String s) => "'${s.replaceAll("'", "''")}'";

  /// Arma un Lyricsfile 1.0 (para publicar en LRCLIB con tiempos por palabra).
  static String toLyricsfile({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    required List<LyricLine> lines,
    required String plain,
  }) {
    final b = StringBuffer()
      ..writeln("version: '1.0'")
      ..writeln('metadata:')
      ..writeln('  title: ${_yamlString(title)}')
      ..writeln('  artist: ${_yamlString(artist)}');
    if (album != null && album.isNotEmpty) b.writeln('  album: ${_yamlString(album)}');
    if (durationMs != null && durationMs > 0) b.writeln('  duration_ms: $durationMs');
    b
      ..writeln('  instrumental: false')
      ..writeln('lines:');
    for (final l in lines) {
      b
        ..writeln('  - text: ${_yamlString(l.text)}')
        ..writeln('    start_ms: ${l.timestamp.inMilliseconds}');
      if (l.end != null) b.writeln('    end_ms: ${l.end!.inMilliseconds}');
      if (l.words.isNotEmpty) {
        b.writeln('    words:');
        for (final w in l.words) {
          b
            ..writeln('      - text: ${_yamlString(w.text)}')
            ..writeln('        start_ms: ${w.start.inMilliseconds}');
          if (w.end != null) b.writeln('        end_ms: ${w.end!.inMilliseconds}');
        }
      }
    }
    b.writeln('plain: |');
    for (final line in plain.split('\n')) {
      b.writeln('  $line');
    }
    return b.toString();
  }
}
