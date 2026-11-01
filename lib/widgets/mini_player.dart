import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../providers.dart';
import '../services/now_playing_service.dart';
import '../theme/app_theme.dart';
import 'artwork_thumb.dart';
import 'song_play.dart';

/// Barrita de "lo que suena" que queda abajo en las otras pestañas, como
/// en Apple Music y Spotify: carátula, título, play/pausa y siguiente. Al
/// tocarla se abre Reproduciendo.
class MiniPlayer extends ConsumerWidget {
  final VoidCallback onOpen;

  const MiniPlayer({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(nowPlayingControllerProvider);
    return ValueListenableBuilder<Song?>(
      valueListenable: pendingPlay,
      builder: (context, pending, _) {
        final track = c.track;
        if (track == null && pending == null) return const SizedBox.shrink();
        final title = pending?.title ?? track!.title;
        final artist = pending?.artist ?? track!.artist;
        final fromMic = pending == null && (track?.fromMicrophone ?? false);
        final playing = track?.isPlaying ?? false;
        final accent = Theme.of(context).colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Material(
                color: AppTheme.surface.withValues(alpha: 0.82),
                child: InkWell(
                  onTap: onOpen,
                  child: Container(
                    height: 60,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: Row(
                      children: [
                        ArtworkThumb(
                          key: ValueKey('mini|$title|$artist'),
                          title: title,
                          artist: artist,
                          bytes: pending == null ? track?.albumArt : null,
                          imageUrl: pending?.artworkUrl,
                          size: 44,
                          borderRadius: 8,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                pending != null
                                    ? 'Poniendo la canción…'
                                    : _subtitle(track!, artist),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if (pending != null)
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: accent),
                            ),
                          )
                        else if (!fromMic) ...[
                          IconButton(
                            tooltip: playing ? 'Pausar' : 'Reproducir',
                            iconSize: 30,
                            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            onPressed: c.togglePlayPause,
                          ),
                          IconButton(
                            tooltip: 'Siguiente',
                            iconSize: 28,
                            icon: const Icon(Icons.fast_forward_rounded),
                            onPressed: c.skipNext,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _subtitle(NowPlayingTrack t, String artist) {
    final app = t.sourceAppName;
    if (app == null) return artist;
    return '$artist · $app';
  }
}
