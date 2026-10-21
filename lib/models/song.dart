/// Datos básicos de una canción (título + artista), usados tanto para
/// buscar letras como para representar lo que se está reproduciendo.
class Song {
  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;

  /// URL de carátula ya conocida (ej. viene de Spotify), para no tener
  /// que buscarla en iTunes.
  final String? artworkUrl;

  /// Número de pista dentro del álbum (solo se completa cuando la canción
  /// viene de listar el contenido de un álbum). Sirve para mostrar y
  /// ordenar el tracklist tal cual está en el álbum original.
  final int? trackNumber;

  const Song({
    required this.title,
    required this.artist,
    this.album,
    this.durationSeconds,
    this.artworkUrl,
    this.trackNumber,
  });

  @override
  String toString() => '$title - $artist';

  /// Devuelve esta canción pero con el título/artista de [identity] (y su
  /// carátula, si tiene). Se usa al guardar una letra descargada: siempre
  /// hay que guardarla con el título/artista "de origen" (el que detectó
  /// Now Playing, el que devolvió Spotify, o el que reconoció el
  /// micrófono), nunca con el que devuelve LRCLIB — que puede venir
  /// levemente distinto (mayúsculas, "(Remasterizado)", orden de
  /// featurings, etc.) y rompería la comparación "¿ya la tengo
  /// descargada?" la próxima vez.
  Song withIdentityFrom(Song identity) => Song(
        title: identity.title,
        artist: identity.artist,
        album: album,
        durationSeconds: durationSeconds,
        artworkUrl: identity.artworkUrl ?? artworkUrl,
        trackNumber: identity.trackNumber ?? trackNumber,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'artworkUrl': artworkUrl,
        'trackNumber': trackNumber,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String?,
        durationSeconds: json['durationSeconds'] as int?,
        artworkUrl: json['artworkUrl'] as String?,
        trackNumber: json['trackNumber'] as int?,
      );
}
