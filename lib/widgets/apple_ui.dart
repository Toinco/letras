import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../models/song.dart';
import '../providers.dart';
import '../screens/album_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/song_list_screen.dart';
import '../services/discovery_service.dart';
import '../theme/app_theme.dart';
import 'artwork_thumb.dart';
import 'cached_artwork.dart';
import 'song_play.dart';

// Piezas con el estilo de Apple Music que se repiten en varias pantallas
// (Inicio, perfil, artista, álbum, buscar).

/// Abre la página de un artista a partir de su nombre (lo busca en el
/// catálogo de Apple Music / iTunes).
Future<void> openArtistNamed(BuildContext context, String name, {String? imageUrl}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final catalog = ProviderScope.containerOf(context, listen: false).read(catalogProvider);
  final found = await catalog.searchArtists(name, limit: 5);
  final match = found.where((r) => r.name.toLowerCase() == name.toLowerCase()).firstOrNull ??
      found.firstOrNull;
  if (match == null) {
    messenger.showSnackBar(SnackBar(content: Text('No encontré a $name en el catálogo.')));
    return;
  }
  navigator.push(MaterialPageRoute(
    builder: (_) => ArtistScreen(
      artist: ArtistResult(
        artistId: match.artistId,
        name: match.name,
        genre: match.genre,
        artworkUrl: imageUrl,
      ),
    ),
  ));
}

/// Abre una lista de canciones (con Reproducir y Aleatorio).
void openSongList(BuildContext context, String title, List<Song> songs,
    {String? subtitle, bool ranked = false}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SongListScreen(title: title, subtitle: subtitle, songs: songs, ranked: ranked),
  ));
}

/// Carátula de una canción (la busca si no la trae).
class SongThumb extends StatelessWidget {
  final Song song;
  final double size;
  final double radius;

  const SongThumb({super.key, required this.song, this.size = 48, this.radius = 6});

  @override
  Widget build(BuildContext context) => ArtworkThumb(
        title: song.title,
        artist: song.artist,
        imageUrl: song.artworkUrl,
        size: size,
        borderRadius: radius,
      );
}

/// Los dos botones grandes de Apple Music: Reproducir y Aleatorio.
class PlayShuffleButtons extends StatelessWidget {
  final List<Song> songs;
  final EdgeInsetsGeometry padding;

  const PlayShuffleButtons({
    super.key,
    required this.songs,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: BigPillButton(
              icon: Icons.play_arrow_rounded,
              label: 'Reproducir',
              onTap: songs.isEmpty
                  ? null
                  : () => playSong(context, songs.first, upNext: songs.sublist(1)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BigPillButton(
              icon: Icons.shuffle_rounded,
              label: 'Aleatorio',
              onTap: songs.isEmpty
                  ? null
                  : () {
                      final list = [...songs]..shuffle();
                      playSong(context, list.first, upNext: list.sublist(1));
                    },
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón gris translúcido con ícono y texto del color de acento.
class BigPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const BigPillButton({super.key, required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.white.withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: accent, size: 22),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un número grande con su descripción (estadísticas).
class StatTile extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;

  const StatTile({super.key, required this.value, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 20),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style:
                  const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onSeeAll;

  const SectionHeader({super.key, required this.title, this.subtitle, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (onSeeAll != null)
                      const Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (onSeeAll == null) return header;
    return InkWell(onTap: onSeeAll, child: header);
  }
}

/// Fila horizontal de tapas cuadradas.
class SongCardRow extends StatelessWidget {
  final List<Song> songs;
  final double size;

  const SongCardRow({super.key, required this.songs, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: songs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final s = songs[i];
          return GestureDetector(
            onTap: () => playSong(context, s, upNext: songs.sublist(i + 1)),
            onLongPress: () => showPlayableSongSheet(context, s, upNext: songs.sublist(i + 1)),
            onSecondaryTap: () => showPlayableSongSheet(context, s, upNext: songs.sublist(i + 1)),
            child: SizedBox(
              width: size,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ArtworkThumb(
                    title: s.title,
                    artist: s.artist,
                    imageUrl: s.artworkUrl,
                    size: size,
                    borderRadius: 10,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    s.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Fila de artistas en círculos (con una línea opcional debajo del nombre,
/// por ejemplo cuántas veces lo escuchaste).
class ArtistCircleRow extends StatelessWidget {
  final List<DiscoveryArtist> artists;
  final List<String>? captions;
  final double size;

  const ArtistCircleRow({super.key, required this.artists, this.captions, this.size = 104});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + (captions != null ? 52 : 34),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: artists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final a = artists[i];
          return GestureDetector(
            onTap: () => openArtistNamed(context, a.name, imageUrl: a.imageUrl),
            child: SizedBox(
              width: size,
              child: Column(
                children: [
                  CachedArtwork(
                    url: a.imageUrl,
                    size: size,
                    borderRadius: size / 2,
                    fallbackIcon: Icons.person_rounded,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (captions != null && i < captions!.length)
                    Text(
                      captions![i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class AlbumCardRow extends StatelessWidget {
  final List<AlbumResult> albums;
  final double size;

  const AlbumCardRow({super.key, required this.albums, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: albums.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final a = albums[i];
          return GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
            ),
            child: SizedBox(
              width: size,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CachedArtwork(url: a.artworkUrl, size: size, borderRadius: 10),
                  const SizedBox(height: 7),
                  Text(
                    a.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    a.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Columnas de a cuatro canciones que se deslizan de costado (como los
/// rankings de Apple Music y Spotify).
class RankedPager extends StatelessWidget {
  final List<Song> songs;
  final bool ranked;

  const RankedPager({super.key, required this.songs, this.ranked = false});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columnWidth = width > 700 ? 380.0 : width * 0.86;
    final columns = (songs.length / 4).ceil().clamp(0, 5);
    return SizedBox(
      height: 4 * 60.0,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: columns,
        itemBuilder: (context, c) => SizedBox(
          width: columnWidth,
          child: Column(
            children: [
              for (var i = c * 4; i < c * 4 + 4 && i < songs.length; i++)
                SizedBox(
                  height: 60,
                  child: SongRow(
                    song: songs[i],
                    rank: ranked ? i + 1 : null,
                    onTap: () => playSong(context, songs[i], upNext: songs.sublist(i + 1)),
                    onMore: () =>
                        showPlayableSongSheet(context, songs[i], upNext: songs.sublist(i + 1)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
