import 'lyric_line.dart';
import 'song.dart';

/// De dónde salió una letra. Se muestra chiquito en la pantalla de letra y
/// sirve para saber si tiene sentido ofrecer "publicar en LRCLIB".
enum LyricsSource { lrclib, musixmatch, netease, genius, manual }

/// Resultado de buscar la letra de una canción: incluye la letra plana
/// (sin tiempos) y, si existe, la letra sincronizada línea por línea.
///
/// [translatedLines], si está presente, es la traducción ya calculada al
/// idioma [translationLang] (mismo orden y cantidad que [syncedLyrics]).
/// Se guarda junto con la letra al descargarla para que la traducción
/// también funcione sin conexión. Lo mismo [romanizedLines]: la
/// pronunciación en letras latinas (japonés, coreano, ruso...).
class LyricsResult {
  final Song song;
  final String plainLyrics;
  final List<LyricLine> syncedLyrics;
  final bool instrumental;
  final List<String>? translatedLines;
  final String? translationLang;
  final List<String>? romanizedLines;
  final LyricsSource source;

  /// Id del registro en LRCLIB, si vino de ahí (para agrupar versiones).
  final int? lrclibId;

  /// La letra la corrigió o sincronizó el usuario a mano.
  final bool editedByUser;

  const LyricsResult({
    required this.song,
    required this.plainLyrics,
    this.syncedLyrics = const [],
    this.instrumental = false,
    this.translatedLines,
    this.translationLang,
    this.romanizedLines,
    this.source = LyricsSource.lrclib,
    this.lrclibId,
    this.editedByUser = false,
  });

  bool get hasSyncedLyrics => syncedLyrics.isNotEmpty;
  bool get hasWordSync => syncedLyrics.any((l) => l.hasWordSync);

  /// Las líneas que se traducen/romanizan: las sincronizadas si hay, si no
  /// los renglones de la letra plana.
  List<String> get displayLines =>
      hasSyncedLyrics ? syncedLyrics.map((l) => l.text).toList() : plainLyrics.split('\n');

  LyricsResult copyWith({
    List<String>? translatedLines,
    String? translationLang,
    List<String>? romanizedLines,
    Song? song,
    String? plainLyrics,
    List<LyricLine>? syncedLyrics,
    LyricsSource? source,
    bool? editedByUser,
    bool clearTranslation = false,
  }) {
    return LyricsResult(
      song: song ?? this.song,
      plainLyrics: plainLyrics ?? this.plainLyrics,
      syncedLyrics: syncedLyrics ?? this.syncedLyrics,
      instrumental: instrumental,
      translatedLines: clearTranslation ? null : (translatedLines ?? this.translatedLines),
      translationLang: clearTranslation ? null : (translationLang ?? this.translationLang),
      romanizedLines: clearTranslation ? null : (romanizedLines ?? this.romanizedLines),
      source: source ?? this.source,
      lrclibId: lrclibId,
      editedByUser: editedByUser ?? this.editedByUser,
    );
  }

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'plainLyrics': plainLyrics,
        'instrumental': instrumental,
        'syncedLyrics': syncedLyrics
            .map((l) => {
                  'ms': l.timestamp.inMilliseconds,
                  'text': l.text,
                  if (l.end != null) 'endMs': l.end!.inMilliseconds,
                  if (l.words.isNotEmpty) 'words': l.words.map((w) => w.toJson()).toList(),
                })
            .toList(),
        'translatedLines': translatedLines,
        'translationLang': translationLang,
        'romanizedLines': romanizedLines,
        'source': source.name,
        'lrclibId': lrclibId,
        'editedByUser': editedByUser,
      };

  factory LyricsResult.fromJson(Map<String, dynamic> json) {
    final syncedRaw = json['syncedLyrics'] as List<dynamic>? ?? [];
    final translatedRaw = json['translatedLines'] as List<dynamic>?;
    final romanizedRaw = json['romanizedLines'] as List<dynamic>?;
    final translatedLines = translatedRaw?.map((e) => e as String).toList();
    return LyricsResult(
      song: Song.fromJson(json['song'] as Map<String, dynamic>),
      plainLyrics: json['plainLyrics'] as String? ?? '',
      instrumental: json['instrumental'] as bool? ?? false,
      syncedLyrics: syncedRaw
          .map((e) => LyricLine(
                timestamp: Duration(milliseconds: e['ms'] as int),
                text: e['text'] as String,
                end: e['endMs'] == null ? null : Duration(milliseconds: e['endMs'] as int),
                words: (e['words'] as List<dynamic>?)
                        ?.map((w) => LyricWord.fromJson(w as List<dynamic>))
                        .toList() ??
                    const [],
              ))
          .toList(),
      translatedLines: translatedLines,
      // Las descargas viejas no guardaban el idioma: siempre era español.
      translationLang:
          json['translationLang'] as String? ?? (translatedLines != null ? 'es' : null),
      romanizedLines: romanizedRaw?.map((e) => e as String).toList(),
      source: LyricsSource.values.asNameMap()[json['source']] ?? LyricsSource.lrclib,
      lrclibId: json['lrclibId'] as int?,
      editedByUser: json['editedByUser'] as bool? ?? false,
    );
  }
}
