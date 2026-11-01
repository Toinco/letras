import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_app/models/song.dart';
import 'package:lyrics_app/services/spotify_service.dart';

void main() {
  const wanted = Song(title: 'Blinding Lights', artist: 'The Weeknd', durationSeconds: 200);

  test('elige la misma canción del mismo artista, no un cover', () {
    final best = SpotifyService.bestMatch(wanted, const [
      Song(title: 'Blinding Lights', artist: 'Kids Cover Band', durationSeconds: 180),
      Song(title: 'Blinding Lights', artist: 'The Weeknd', durationSeconds: 200, spotifyUri: 'ok'),
    ]);
    expect(best?.spotifyUri, 'ok');
  });

  test('acepta "(Remastered)" y featurings en el título', () {
    final best = SpotifyService.bestMatch(
      const Song(title: 'Tusa', artist: 'KAROL G, Nicki Minaj'),
      const [Song(title: 'Tusa (Remastered)', artist: 'KAROL G', spotifyUri: 'ok')],
    );
    expect(best?.spotifyUri, 'ok');
  });

  test('sin nada parecido devuelve null', () {
    expect(
      SpotifyService.bestMatch(wanted, const [Song(title: 'Otra cosa', artist: 'Nadie')]),
      isNull,
    );
  });
}
