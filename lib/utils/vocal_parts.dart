import '../models/lyric_line.dart';

/// Un tramo de texto que se "llena" entre [start] y [end]: los caracteres
/// [from, to) de una [VocalPart].
class KaraokeSegment {
  final int from;
  final int to;
  final Duration start;
  final Duration end;

  const KaraokeSegment({
    required this.from,
    required this.to,
    required this.start,
    required this.end,
  });
}

/// Una de las dos voces de una línea: la principal o los coros/segundas
/// voces (lo que va entre paréntesis), con los tiempos de cada palabra.
class VocalPart {
  final String text;
  final List<KaraokeSegment> segments;

  const VocalPart(this.text, this.segments);

  /// Cuántos caracteres ya se "cantaron" en el instante [now] (con
  /// decimales: 3.5 = tres caracteres y la mitad del cuarto).
  double filledChars(Duration now) {
    var filled = 0.0;
    for (final s in segments) {
      if (now >= s.end) {
        filled = s.to.toDouble();
      } else if (now > s.start) {
        final total = (s.end - s.start).inMicroseconds;
        final frac = total <= 0 ? 1.0 : (now - s.start).inMicroseconds / total;
        return s.from + (s.to - s.from) * frac;
      } else {
        break;
      }
    }
    return filled;
  }

  /// Momento en que termina de cantarse esta parte.
  Duration get end => segments.isEmpty ? Duration.zero : segments.last.end;
}

/// Cómo se muestra una línea: voz principal arriba y, si hay, los coros
/// más chicos abajo a la derecha (como Apple Music).
class LinePresentation {
  final VocalPart? main;
  final VocalPart? background;

  const LinePresentation({this.main, this.background});
}

/// Separa "Te quiero (te quiero)" en voz principal "Te quiero" y coro
/// "te quiero". Si [splitBackground] es false, todo queda como principal.
///
/// Si la línea trae tiempos por palabra se usan tal cual; si no, se
/// reparten de forma pareja entre [line.timestamp] y [estimatedEnd]
/// según la posición de cada palabra (así el karaoke estimado y el
/// exacto usan el mismo camino).
LinePresentation presentLine(
  LyricLine line, {
  required Duration estimatedEnd,
  bool splitBackground = true,
}) {
  final words = line.hasWordSync ? line.words : _estimateWords(line, estimatedEnd);
  if (words.isEmpty) return const LinePresentation();

  final mainWords = <_TimedText>[];
  final bgWords = <_TimedText>[];
  var depth = 0;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final end = w.end ?? (i + 1 < words.length ? words[i + 1].start : (line.end ?? estimatedEnd));
    // Repartimos cada caracter según si está adentro o afuera de un
    // paréntesis: una "palabra" puede ser "(oh" o "yeah)".
    final mainBuf = StringBuffer();
    final bgBuf = StringBuffer();
    for (final ch in w.text.split('')) {
      if (splitBackground && ch == '(') {
        depth++;
        continue;
      }
      if (splitBackground && ch == ')') {
        if (depth > 0) depth--;
        continue;
      }
      (depth > 0 ? bgBuf : mainBuf).write(ch);
    }
    if (mainBuf.isNotEmpty) mainWords.add(_TimedText(mainBuf.toString(), w.start, end));
    if (bgBuf.isNotEmpty) bgWords.add(_TimedText(bgBuf.toString(), w.start, end));
  }

  return LinePresentation(main: _build(mainWords), background: _build(bgWords));
}

class _TimedText {
  final String text;
  final Duration start;
  final Duration end;
  _TimedText(this.text, this.start, this.end);
}

VocalPart? _build(List<_TimedText> parts) {
  final buffer = StringBuffer();
  final segments = <KaraokeSegment>[];
  for (final p in parts) {
    var text = p.text;
    // Sin espacios dobles ni espacio inicial (pasa al sacar un paréntesis).
    if (buffer.isEmpty) text = text.trimLeft();
    if (buffer.toString().endsWith(' ') && text.startsWith(' ')) text = text.trimLeft();
    if (text.isEmpty) continue;
    final from = buffer.length;
    buffer.write(text);
    segments.add(KaraokeSegment(from: from, to: buffer.length, start: p.start, end: p.end));
  }
  final full = buffer.toString();
  final trimmed = full.trimRight();
  if (trimmed.trim().isEmpty) return null;
  return VocalPart(trimmed, [
    for (final s in segments)
      if (s.from < trimmed.length)
        KaraokeSegment(
          from: s.from,
          to: s.to.clamp(0, trimmed.length),
          start: s.start,
          end: s.end,
        ),
  ]);
}

/// Inventa tiempos por palabra para una línea que no los trae: cada
/// palabra arranca proporcionalmente a su posición en el texto.
List<LyricWord> _estimateWords(LyricLine line, Duration end) {
  final text = line.text;
  if (text.trim().isEmpty) return const [];
  final total = (end - line.timestamp).inMicroseconds;
  final matches = RegExp(r'\S+\s*').allMatches(text).toList();
  final length = text.length;
  return [
    for (final m in matches)
      LyricWord(
        start: line.timestamp + Duration(microseconds: total * m.start ~/ length),
        end: line.timestamp + Duration(microseconds: total * m.end ~/ length),
        text: m.group(0)!,
      ),
  ];
}
