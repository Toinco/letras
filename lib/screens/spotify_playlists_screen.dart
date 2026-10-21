import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/spotify_playlist_sync.dart';
import '../services/spotify_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cached_artwork.dart';
import '../providers.dart';

/// Tus playlists de Spotify: bajar todas las letras de una de una vez, o
/// marcarla para que las canciones nuevas se bajen solas.
class SpotifyPlaylistsScreen extends ConsumerStatefulWidget {
  const SpotifyPlaylistsScreen({super.key});

  @override
  ConsumerState<SpotifyPlaylistsScreen> createState() => _SpotifyPlaylistsScreenState();
}

class _SpotifyPlaylistsScreenState extends ConsumerState<SpotifyPlaylistsScreen> {
  late final _spotify = ref.read(spotifyProvider);
  late final _auth = ref.read(spotifyAuthProvider);
  final _sync = SpotifyPlaylistSync();
  late final _helper = ref.read(downloadHelperProvider);

  List<SpotifyPlaylist>? _playlists;
  Set<String> _auto = {};
  String? _error;
  bool _needsReconnect = false;

  // Descarga en curso: id de la playlist y progreso.
  String? _downloadingId;
  int _done = 0;
  int _total = 0;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _playlists = null;
    });
    if (!await _auth.isConnected()) {
      setState(() => _error = 'Primero conecta tu cuenta de Spotify en Ajustes.');
      return;
    }
    if (!await _auth.canReadPlaylists()) {
      setState(() {
        _needsReconnect = true;
        _error = 'Para ver tus playlists, Spotify necesita un permiso nuevo. '
            'Reconecta tu cuenta (es un toque).';
      });
      return;
    }
    try {
      final lists = await _spotify.getPlaylists();
      final auto = await _sync.autoPlaylists();
      if (mounted) {
        setState(() {
          _playlists = lists;
          _auto = auto;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _reconnect() async {
    try {
      await _auth.connect();
      _needsReconnect = false;
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo conectar: $e')));
      }
    }
  }

  Future<void> _downloadAll(SpotifyPlaylist p) async {
    setState(() {
      _downloadingId = p.id;
      _done = 0;
      _total = p.trackCount;
      _cancel = false;
    });
    try {
      final songs = await _spotify.getPlaylistSongs(p.id);
      if (!mounted) return;
      setState(() => _total = songs.length);
      final outcomes = await _helper.downloadMany(
        songs,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
        isCancelled: () => _cancel,
      );
      final ok = outcomes.where((o) => o.success).length;
      final missing = outcomes.where((o) => !o.success).length;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '"${p.name}": $ok letras listas'
            '${missing > 0 ? ', $missing sin letra disponible' : ''}.',
          ),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _downloadingId = null);
    }
  }

  Future<void> _toggleAuto(SpotifyPlaylist p, bool value) async {
    await _sync.setAuto(p.id, value);
    setState(() => value ? _auto.add(p.id) : _auto.remove(p.id));
    if (value && _downloadingId == null) _downloadAll(p);
  }

  @override
  Widget build(BuildContext context) {
    final lists = _playlists;
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists de Spotify')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.textSecondary)),
                    const SizedBox(height: 16),
                    if (_needsReconnect)
                      ElevatedButton(onPressed: _reconnect, child: const Text('Reconectar Spotify'))
                    else
                      OutlinedButton(onPressed: _load, child: const Text('Reintentar')),
                  ],
                ),
              ),
            )
          : lists == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    itemCount: lists.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return const Padding(
                          padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
                          child: Text(
                            'Con "automático", las canciones que se agreguen a esa playlist '
                            'se descargan solas cada vez que abres la app.',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                          ),
                        );
                      }
                      final p = lists[i - 1];
                      final downloading = _downloadingId == p.id;
                      return Card(
                        color: AppTheme.surface,
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: p.imageUrl == null
                                          ? const ColoredBox(
                                              color: Colors.white10,
                                              child: Icon(Icons.queue_music_rounded),
                                            )
                                          : CachedArtwork(url: p.imageUrl!, size: 56),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w700)),
                                        Text(
                                          '${p.trackCount} canciones · ${p.owner}',
                                          style: const TextStyle(
                                              color: AppTheme.textSecondary, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (downloading) ...[
                                LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
                                Row(
                                  children: [
                                    Text('Descargando $_done / $_total',
                                        style: const TextStyle(color: AppTheme.textSecondary)),
                                    const Spacer(),
                                    TextButton(
                                      onPressed: () => setState(() => _cancel = true),
                                      child: const Text('Cancelar'),
                                    ),
                                  ],
                                ),
                              ] else
                                Row(
                                  children: [
                                    TextButton.icon(
                                      onPressed:
                                          _downloadingId == null ? () => _downloadAll(p) : null,
                                      icon: const Icon(Icons.download_rounded),
                                      label: const Text('Descargar todas'),
                                    ),
                                    const Spacer(),
                                    const Text('Automático'),
                                    Switch(
                                      value: _auto.contains(p.id),
                                      onChanged: (v) => _toggleAuto(p, v),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
