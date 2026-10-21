import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/song.dart';
import '../services/genius_service.dart';
import '../theme/app_theme.dart';
import 'artwork_thumb.dart';

/// Sección "Info" de la pantalla de letra: de qué habla la canción (según
/// Genius), quién la escribió, cuándo salió, etc. Es la "sección
/// especializada" con la que se puede interactuar además de la letra en
/// sí, tal como se pidió.
class SongInfoView extends StatelessWidget {
  final Song song;
  final bool loading;
  final bool tokenMissing;
  final SongInfo? info;
  final VoidCallback onOpenSettings;

  const SongInfoView({
    super.key,
    required this.song,
    required this.loading,
    required this.tokenMissing,
    required this.info,
    required this.onOpenSettings,
  });

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 15, height: 1.3)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (tokenMissing) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_stories_rounded, size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text(
                'Configura tu token de Genius en Ajustes para ver de qué '
                'habla esta canción, quién la escribió y más.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: onOpenSettings, child: const Text('Ir a Ajustes')),
            ],
          ),
        ),
      );
    }

    final data = info;
    if (data == null || data.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No encontramos información de esta canción en Genius.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ArtworkThumb(
                title: song.title,
                artist: song.artist,
                imageUrl: data.artworkUrl,
                size: 64,
                borderRadius: 12,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title.isEmpty ? '(Sin título)' : song.title,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(song.artist, style: const TextStyle(color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (data.description != null) ...[
            _infoRow('De qué habla', data.description!),
          ],
          if (data.writers.isNotEmpty) _infoRow('Escrita por', data.writers.join(', ')),
          if (data.producers.isNotEmpty) _infoRow('Producida por', data.producers.join(', ')),
          if (data.releaseDate != null) _infoRow('Fecha de lanzamiento', data.releaseDate!),
          if (data.albumName != null) _infoRow('Álbum', data.albumName!),
          if (data.geniusUrl != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  launchUrl(Uri.parse(data.geniusUrl!), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Ver en Genius'),
            ),
          ],
        ],
      ),
    );
  }
}
