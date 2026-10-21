/// Una palabra (o pedazo de palabra) con su tiempo propio, para el karaoke
/// palabra por palabra. [text] incluye los espacios que la separan de la
/// siguiente, así que unir todos los [text] de una línea da la línea entera.
class LyricWord {
  final Duration start;
  final Duration? end;
  final String text;

  const LyricWord({required this.start, this.end, required this.text});

  List<Object?> toJson() => [start.inMilliseconds, end?.inMilliseconds, text];

  factory LyricWord.fromJson(List<dynamic> json) => LyricWord(
        start: Duration(milliseconds: json[0] as int),
        end: json[1] == null ? null : Duration(milliseconds: json[1] as int),
        text: json[2] as String,
      );
}

/// Representa una sola línea de una letra sincronizada (formato LRC).
///
/// [timestamp] es el momento de la canción en el que empieza esta línea.
/// Si la letra viene sincronizada por palabra, [words] trae el tiempo de
/// cada una; si no, está vacía y el karaoke se estima.
class LyricLine {
  final Duration timestamp;
  final String text;
  final Duration? end;
  final List<LyricWord> words;

  const LyricLine({
    required this.timestamp,
    required this.text,
    this.end,
    this.words = const [],
  });

  bool get hasWordSync => words.isNotEmpty;

  LyricLine copyWith({Duration? timestamp, String? text, List<LyricWord>? words}) => LyricLine(
        timestamp: timestamp ?? this.timestamp,
        text: text ?? this.text,
        end: end,
        words: words ?? this.words,
      );

  /// Corre toda la línea (y sus palabras) [delta] en el tiempo.
  LyricLine shifted(Duration delta) {
    Duration clamp(Duration d) => d < Duration.zero ? Duration.zero : d;
    return LyricLine(
      timestamp: clamp(timestamp + delta),
      text: text,
      end: end == null ? null : clamp(end! + delta),
      words: [
        for (final w in words)
          LyricWord(
            start: clamp(w.start + delta),
            end: w.end == null ? null : clamp(w.end! + delta),
            text: w.text,
          ),
      ],
    );
  }

  @override
  String toString() => '[$timestamp] $text';
}
