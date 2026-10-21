import 'package:flutter/material.dart';

import '../models/artist_result.dart';
import '../theme/app_theme.dart';
import 'cached_artwork.dart';

/// Tarjeta para mostrar un artista en una lista de resultados: foto (o
/// ícono de respaldo, ya que iTunes no siempre expone una) + nombre +
/// género.
class ArtistCard extends StatelessWidget {
  final ArtistResult artist;
  final VoidCallback onTap;

  const ArtistCard({super.key, required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              ClipOval(
                child: CachedArtwork(
                  url: artist.artworkUrl,
                  size: 52,
                  fallbackIcon: Icons.person_rounded,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artist.name.isEmpty ? '(Sin nombre)' : artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    if (artist.genre != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        artist.genre!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                      ),
                    ],
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
