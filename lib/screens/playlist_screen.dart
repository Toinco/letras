import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lyrics_result.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/song_card.dart';
import 'lyrics_screen.dart';
import '../providers.dart';

/// Una playlist de letras: se ordena arrastrando y se saca deslizando.
class PlaylistScreen extends ConsumerStatefulWidget {
  final LyricsPlaylist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  late final _service = ref.read(playlistProvider);
  late String _name = widget.playlist.name;
  List<LyricsResult> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await _service.songs(widget.playlist.id);
    if (mounted) {
      setState(() {
        _songs = songs;
        _loading = false;
      });
    }
  }

  Future<void> _rename() async {
    final name = await askPlaylistName(context, initial: _name);
    if (name == null) return;
    await _service.rename(widget.playlist.id, name);
    setState(() => _name = name);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Borrar "$_name"?'),
        content: const Text('Las letras siguen en Descargas; solo se borra la playlist.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await _service.delete(widget.playlist.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      _songs.insert(newIndex, _songs.removeAt(oldIndex));
    });
    _service.reorder(widget.playlist.id, _songs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(tooltip: 'Renombrar', icon: const Icon(Icons.edit_rounded), onPressed: _rename),
          IconButton(
            tooltip: 'Borrar playlist',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _delete,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Vacía. En Descargas, mantén apretada una letra para agregarla aquí.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _songs.length,
                  onReorder: _onReorder,
                  itemBuilder: (context, i) {
                    final r = _songs[i];
                    return Dismissible(
                      key: ValueKey('${r.song.artist}|${r.song.title}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.playlist_remove_rounded),
                      ),
                      onDismissed: (_) {
                        _service.remove(widget.playlist.id, r);
                        setState(() => _songs.removeAt(i));
                      },
                      child: SongCard(
                        song: r.song,
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle_rounded, color: AppTheme.textSecondary),
                          ),
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => LyricsScreen(result: r)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
