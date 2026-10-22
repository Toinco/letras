import 'package:flutter_test/flutter_test.dart';

import 'package:lyrics_app/services/artwork_service.dart';

Map<String, dynamic> _r(String track, String artist, String album, {int ms = 150000}) => {
      'trackName': track,
      'artistName': artist,
      'collectionName': album,
      'trackTimeMillis': ms,
      'artworkUrl100': 'https://x/$album/100x100bb.jpg',
    };

void main() {
  // Lo que devuelve iTunes de verdad para "Olivia Rodrigo love is embarrassing".
  final results = [
    _r('good 4 u', 'Olivia Rodrigo', 'SOUR', ms: 178148),
    _r('deja vu', 'Olivia Rodrigo', 'SOUR', ms: 215508),
    _r('love is embarrassing', 'Olivia Rodrigo', 'GUTS', ms: 154517),
    _r('love is embarrassing', 'Olivia Rodrigo', 'GUTS (spilled)', ms: 154517),
    _r('Love Is Embarrassing (Instrumental)', 'Piano Dreamers',
        'Piano Dreamers Cover Olivia Rodrigo, Vol. 2 (Instrumental)'),
  ];

  test('No se queda con otra canción del mismo artista', () {
    final best = ArtworkService.pickBest(results, 'love is embarrassing', 'Olivia Rodrigo');
    expect(best?['collectionName'], 'GUTS');
  });

  test('El álbum que informa la app elige la edición', () {
    final best = ArtworkService.pickBest(results, 'love is embarrassing', 'Olivia Rodrigo',
        album: 'GUTS (spilled)');
    expect(best?['collectionName'], 'GUTS (spilled)');
  });

  test('Sin coincidencia, mejor ninguna que una equivocada', () {
    expect(ArtworkService.pickBest(results, 'vampire', 'Olivia Rodrigo'), isNull);
    expect(ArtworkService.pickBest(results, 'love is embarrassing', 'Otra Artista'), isNull);
  });

  test('Versiones cover/karaoke pierden contra el original', () {
    final best = ArtworkService.pickBest(
      [
        _r('Love Is Embarrassing', 'Olivia Rodrigo', 'Karaoke Hits Vol. 3'),
        _r('love is embarrassing', 'Olivia Rodrigo', 'GUTS'),
      ],
      'Love Is Embarrassing',
      'Olivia Rodrigo',
    );
    expect(best?['collectionName'], 'GUTS');
  });

  test('Deezer se lee igual que iTunes y pide la tapa en 600 px', () {
    final r = ArtworkService.deezerToItunes({
      'title': 'Goten',
      'duration': 150,
      'artist': {'name': 'Lucho SSJ'},
      'album': {
        'title': 'Goten',
        'cover_xl': 'https://cdn-images.dzcdn.net/images/cover/abc/1000x1000-000000-80-0-0.jpg',
      },
    });
    final best = ArtworkService.pickBest([r], 'Goten', 'Lucho SSJ', durationSeconds: 150);
    expect(ArtworkService.bigArtworkUrl(best!),
        'https://cdn-images.dzcdn.net/images/cover/abc/600x600-000000-80-0-0.jpg');
  });
}
