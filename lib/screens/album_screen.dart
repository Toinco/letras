import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import '../widgets/cached_artwork.dart';
import '../widgets/song_card.dart';
import 'lyrics_screen.dart';
import '../providers.dart';
import '../widgets/desktop.dart';

/// Muestra un álbum: carátula grande, datos, y el listado completo de sus
/// canciones. Tal como se pidió: "si buscas un álbum te aparezca el álbum
/// y adentro todas las canciones respectivamente".
class AlbumScreen extends ConsumerStatefulWidget {
  final AlbumResult album;

  const AlbumScreen({super.key, required this.album});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  late final _catalogService = ref.read(catalogProvider);
  late final _storage = ref.read(storageProvider);
  late final _downloadHelper = ref.read(downloadHelperProvider);

  List<Song> _tracks = [];
  bool _loading = true;
  String? _error;

  bool _bulkRunning = false;
  bool _bulkCancelled = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tracks = await _catalogService.getAlbumTracks(widget.album.collectionId);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
        _error = tracks.isEmpty ? 'No se pudo cargar el listado de canciones.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar el álbum: $e';
      });
    }
  }

  Future<void> _openTrack(Song song) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final saved = await _storage.getSaved(song.title, song.artist);
      final result = saved ??
          await ref.read(lyricsFinderProvider).find(song.title, song.artist, durationSeconds: song.durationSeconds);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (result != null) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => LyricsScreen(result: result, originalSong: song)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró la letra de esta canción.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error buscando la letra: $e')),
      );
    }
  }

  Future<void> _downloadAll() async {
    if (_bulkRunning || _tracks.isEmpty) return;
    setState(() {
      _bulkRunning = true;
      _bulkCancelled = false;
      _bulkDone = 0;
      _bulkTotal = _tracks.length;
    });
    final outcomes = await _downloadHelper.downloadMany(
      _tracks,
      isCancelled: () => _bulkCancelled,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() => _bulkDone = done);
      },
    );
    if (!mounted) return;
    setState(() => _bulkRunning = false);
    final newlyDownloaded = outcomes.where((o) => o.success && !o.alreadyHad).length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Se descargaron $newlyDownloaded letras nuevas del álbum.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(title: Text(album.title, overflow: TextOverflow.ellipsis)),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        CachedArtwork(
                          url: album.artworkUrl,
                          size: 88,
                          borderRadius: 14,
                          fallbackIcon: Icons.album_rounded,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                album.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 4),
                              Text(album.artist,
                                  style: const TextStyle(color: AppTheme.textSecondary)),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if (album.releaseYear != null) '${album.releaseYear}',
                                  if (album.trackCount != null) '${album.trackCount} canciones',
                                ].join(' · '),
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        const Spacer(),
                        if (!_bulkRunning)
                          TextButton(
                            onPressed: _tracks.isEmpty ? null : _downloadAll,
                            child: const Text('Descargar todas'),
                          ),
                      ],
                    ),
                  ),
                  if (_bulkRunning)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Column(
                        children: [
                          LinearProgressIndicator(
                            value: _bulkTotal > 0 ? _bulkDone / _bulkTotal : null,
                            backgroundColor: AppTheme.surface,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '$_bulkDone / $_bulkTotal',
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                              ),
                              TextButton(
                                onPressed: () => setState(() => _bulkCancelled = true),
                                child: const Text('Cancelar'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(_error!,
                                  style: const TextStyle(color: AppTheme.textSecondary)),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            itemCount: _tracks.length,
                            itemBuilder: (context, index) {
                              final track = _tracks[index];
                              return SongCard(
                                song: track,
                                subtitleOverride: track.trackNumber != null
                                    ? '${track.trackNumber}. ${track.artist}'
                                    : track.artist,
                                onTap: () => _openTrack(track),
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
