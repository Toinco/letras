import 'dart:math';

import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_theme.dart';
import '../widgets/artwork_thumb.dart';
import '../widgets/desktop.dart';
import '../widgets/song_play.dart';

/// Una lista de canciones para escuchar de corrido (un mix, tus más
/// escuchadas, un ranking), con los botones Reproducir y Aleatorio arriba,
/// como en Apple Music.
class SongListScreen extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Song> songs;

  /// Mostrar el puesto (1, 2, 3...) en vez de la carátula chica.
  final bool ranked;

  const SongListScreen({
    super.key,
    required this.title,
    this.subtitle,
    required this.songs,
    this.ranked = false,
  });

  void _playFrom(BuildContext context, int index) {
    playSong(context, songs[index], upNext: songs.sublist(index + 1));
  }

  void _shuffle(BuildContext context) {
    final list = [...songs]..shuffle(Random());
    playSong(context, list.first, upNext: list.sublist(1));
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final covers = songs.take(4).toList();
    return ReadableFrame(
      maxWidth: 820,
      child: Scaffold(
        appBar: AppBar(),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  children: [
                    if (covers.isNotEmpty) Center(child: SongCollage(songs: covers, size: 220)),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, color: accent, fontWeight: FontWeight.w600),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _BigButton(
                            icon: Icons.play_arrow_rounded,
                            label: 'Reproducir',
                            onTap: songs.isEmpty ? null : () => _playFrom(context, 0),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BigButton(
                            icon: Icons.shuffle_rounded,
                            label: 'Aleatorio',
                            onTap: songs.isEmpty ? null : () => _shuffle(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (context, i) => SongRow(
                song: songs[i],
                rank: ranked ? i + 1 : null,
                onTap: () => _playFrom(context, i),
                onMore: () =>
                    showPlayableSongSheet(context, songs[i], upNext: songs.sublist(i + 1)),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _BigButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
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

/// Una fila de canción: carátula (o puesto), título, artista y "más".
class SongRow extends StatelessWidget {
  final Song song;
  final int? rank;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final double artSize;

  const SongRow({
    super.key,
    required this.song,
    this.rank,
    required this.onTap,
    required this.onMore,
    this.artSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onMore,
      onSecondaryTap: onMore,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            ArtworkThumb(
              title: song.title,
              artist: song.artist,
              imageUrl: song.artworkUrl,
              size: artSize,
              borderRadius: 6,
            ),
            if (rank != null)
              SizedBox(
                width: 34,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Más',
              icon: const Icon(Icons.more_horiz_rounded, color: AppTheme.textSecondary),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

/// Cuatro carátulas en cuadrícula (o una sola, grande), como las tapas de
/// los mixes de Apple Music.
class SongCollage extends StatelessWidget {
  final List<Song> songs;
  final double size;

  const SongCollage({super.key, required this.songs, required this.size});

  @override
  Widget build(BuildContext context) {
    if (songs.length < 4) {
      return ArtworkThumb(
        title: songs.first.title,
        artist: songs.first.artist,
        imageUrl: songs.first.artworkUrl,
        size: size,
        borderRadius: 14,
      );
    }
    final half = size / 2;
    Widget tile(Song s) => ArtworkThumb(
          title: s.title,
          artist: s.artist,
          imageUrl: s.artworkUrl,
          size: half,
          borderRadius: 0,
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Row(children: [tile(songs[0]), tile(songs[1])]),
            Row(children: [tile(songs[2]), tile(songs[3])]),
          ],
        ),
      ),
    );
  }
}
