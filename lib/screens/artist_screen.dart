import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../theme/app_theme.dart';
import '../widgets/album_card.dart';
import '../widgets/cached_artwork.dart';
import 'album_screen.dart';
import '../providers.dart';
import '../widgets/desktop.dart';

/// Muestra un artista: foto y su discografía completa. Tal como se pidió:
/// "que puedas buscar por artista y que te aparezca el artista y su
/// discografía".
class ArtistScreen extends ConsumerStatefulWidget {
  final ArtistResult artist;

  const ArtistScreen({super.key, required this.artist});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  late final _catalogService = ref.read(catalogProvider);

  List<AlbumResult> _albums = [];
  bool _loading = true;
  String? _artworkUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final albums = await _catalogService.getArtistAlbums(widget.artist.artistId);
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _artworkUrl =
          widget.artist.artworkUrl ?? (albums.isNotEmpty ? albums.first.artworkUrl : null);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.artist.name, overflow: TextOverflow.ellipsis)),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        ClipOval(
                          child: CachedArtwork(
                            url: _artworkUrl,
                            size: 72,
                            fallbackIcon: Icons.person_rounded,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.artist.name,
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                              ),
                              if (widget.artist.genre != null) ...[
                                const SizedBox(height: 4),
                                Text(widget.artist.genre!,
                                    style: const TextStyle(color: AppTheme.textSecondary)),
                              ],
                              const SizedBox(height: 2),
                              Text(
                                '${_albums.length} álbumes',
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: _albums.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'No se encontró discografía para este artista.',
                                style: TextStyle(color: AppTheme.textSecondary),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            itemCount: _albums.length,
                            itemBuilder: (context, index) {
                              final album = _albums[index];
                              return AlbumCard(
                                album: album,
                                showArtist: false,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => AlbumScreen(album: album)),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}
