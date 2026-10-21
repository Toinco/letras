/// Un álbum encontrado al buscar o al listar la discografía de un
/// artista (viene de la API pública de iTunes).
class AlbumResult {
  final int collectionId;
  final String title;
  final String artist;
  final String? artworkUrl;
  final String? releaseDate; // formato ISO tal cual lo devuelve iTunes
  final int? trackCount;

  const AlbumResult({
    required this.collectionId,
    required this.title,
    required this.artist,
    this.artworkUrl,
    this.releaseDate,
    this.trackCount,
  });

  int? get releaseYear {
    if (releaseDate == null || releaseDate!.length < 4) return null;
    return int.tryParse(releaseDate!.substring(0, 4));
  }
}
