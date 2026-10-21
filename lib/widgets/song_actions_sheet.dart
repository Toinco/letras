import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_theme.dart';
import 'artwork_thumb.dart';

/// Acción extra para la hoja de una canción.
class SongSheetAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const SongSheetAction({required this.icon, required this.label, required this.onTap});
}

/// Hoja inferior tipo "single" de Apple Music: carátula + título/artista
/// arriba, y abajo las acciones rápidas (ver letra, descargar).
Future<void> showSongActionsSheet(
  BuildContext context, {
  required Song song,
  Uint8List? artworkBytes,
  VoidCallback? onViewLyrics,
  Future<void> Function()? onDownload,
  List<SongSheetAction> extraActions = const [],
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  ArtworkThumb(
                    title: song.title,
                    artist: song.artist,
                    bytes: artworkBytes,
                    imageUrl: song.artworkUrl,
                    size: 56,
                    borderRadius: 10,
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
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                ],
              ),
              const SizedBox(height: 8),
              const Divider(height: 24, color: Colors.white12),
              if (onViewLyrics != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.lyrics_rounded, color: Colors.white),
                  title: const Text('Ver letra'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onViewLyrics();
                  },
                ),
              if (onDownload != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download_rounded, color: Colors.white),
                  title: const Text('Descargar letra'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onDownload();
                  },
                ),
              for (final action in extraActions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(action.icon, color: Colors.white),
                  title: Text(action.label),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    action.onTap();
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}
