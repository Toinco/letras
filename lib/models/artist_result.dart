/// Un artista encontrado al buscar (viene de la API pública de iTunes).
class ArtistResult {
  final int artistId;
  final String name;
  final String? genre;

  /// La búsqueda de artistas de iTunes no trae foto: se resuelve aparte,
  /// de forma perezosa, usando la carátula del álbum más reciente.
  final String? artworkUrl;

  const ArtistResult({
    required this.artistId,
    required this.name,
    this.genre,
    this.artworkUrl,
  });

  ArtistResult copyWithArtwork(String? artworkUrl) => ArtistResult(
        artistId: artistId,
        name: name,
        genre: genre,
        artworkUrl: artworkUrl,
      );
}
