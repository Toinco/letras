import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import 'artwork_thumb.dart';

/// Tarjeta simple para mostrar una canción en una lista (resultados de
/// búsqueda, descargas, etc.), estilo minimalista.
///
/// Si [selectionMode] es `true`, muestra un círculo de selección en vez de
/// (o antes de) la carátula, para el modo "elegir varias" del buscador.
class SongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool selectionMode;
  final bool selected;
  final String? subtitleOverride;

  const SongCard({
    super.key,
    required this.song,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.selectionMode = false,
    this.selected = false,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              if (selectionMode) ...[
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: selected ? Theme.of(context).colorScheme.primary : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
              ],
              ArtworkThumb(
                title: song.title,
                artist: song.artist,
                imageUrl: song.artworkUrl,
                size: 52,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title.isEmpty ? '(Sin título)' : song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleOverride ?? song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                    ),
                  ],
                ),
              ),
              if (trailing != null && !selectionMode) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
