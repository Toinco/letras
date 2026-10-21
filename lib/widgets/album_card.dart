import 'package:flutter/material.dart';

import '../models/album_result.dart';
import '../theme/app_theme.dart';
import 'cached_artwork.dart';

/// Tarjeta para mostrar un álbum en una lista de resultados o en una
/// discografía: carátula cuadrada + título + artista + año.
class AlbumCard extends StatelessWidget {
  final AlbumResult album;
  final VoidCallback onTap;
  final bool showArtist;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.showArtist = true,
  });

  @override
  Widget build(BuildContext context) {
    final year = album.releaseYear;
    final subtitle = [
      if (showArtist) album.artist,
      if (year != null) '$year',
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              CachedArtwork(
                url: album.artworkUrl,
                size: 52,
                borderRadius: 8,
                fallbackIcon: Icons.album_rounded,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title.isEmpty ? '(Sin título)' : album.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
