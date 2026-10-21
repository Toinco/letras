import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Imagen de carátula/artista con caché en memoria y disco. A diferencia
/// de [ArtworkThumb] (que busca la carátula por título/artista), esta
/// recibe la URL ya resuelta (álbumes y artistas de iTunes ya la traen) y
/// solo se encarga de mostrarla rápido y sin volver a descargarla cada vez
/// que la lista se reconstruye — antes, con `Image.network` simple, cada
/// scroll o cada `setState` volvía a pedir la misma imagen por red.
class CachedArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final double borderRadius;
  final IconData fallbackIcon;

  const CachedArtwork({
    super.key,
    required this.url,
    this.size = 52,
    this.borderRadius = 10,
    this.fallbackIcon = Icons.music_note_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);

    Widget placeholder() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: AppTheme.surface, borderRadius: radius),
          child: Icon(fallbackIcon, color: AppTheme.textSecondary, size: size * 0.4),
        );

    final effectiveUrl = url;
    if (effectiveUrl == null || effectiveUrl.isEmpty) return placeholder();

    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: effectiveUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: (size * 2).round(),
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => placeholder(),
        errorWidget: (_, __, ___) => placeholder(),
      ),
    );
  }
}
