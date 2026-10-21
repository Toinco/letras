import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lyrics_result.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../providers.dart';

/// Pide un nombre (para crear o renombrar una playlist).
Future<String?> askPlaylistName(BuildContext context, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(initial.isEmpty ? 'Nueva playlist' : 'Renombrar'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Nombre'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Guardar'),
        ),
      ],
    ),
  ).then((v) => (v == null || v.trim().isEmpty) ? null : v.trim());
}

/// Hoja para agregar/sacar una letra de las playlists (con casillas).
Future<void> showAddToPlaylistSheet(BuildContext context, LyricsResult song) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AddToPlaylistSheet(song: song),
  );
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  final LyricsResult song;

  const _AddToPlaylistSheet({required this.song});

  @override
  ConsumerState<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  late final _service = ref.read(playlistProvider);
  List<LyricsPlaylist> _playlists = [];
  Set<int> _containing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lists = await _service.list();
    final containing = await _service.playlistsContaining(widget.song);
    if (mounted) {
      setState(() {
        _playlists = lists;
        _containing = containing;
      });
    }
  }

  Future<void> _toggle(LyricsPlaylist p, bool add) async {
    add ? await _service.add(p.id, widget.song) : await _service.remove(p.id, widget.song);
    await _load();
  }

  Future<void> _create() async {
    final name = await askPlaylistName(context);
    if (name == null) return;
    final id = await _service.create(name);
    await _service.add(id, widget.song);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Agregar "${widget.song.song.title}" a...',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final p in _playlists)
              CheckboxListTile(
                value: _containing.contains(p.id),
                title: Text(p.name),
                subtitle: Text('${p.count} letras'),
                onChanged: (v) => _toggle(p, v ?? false),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Nueva playlist'),
              onTap: _create,
            ),
          ],
        ),
      ),
    );
  }
}
