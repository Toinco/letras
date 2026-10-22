import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lyrics_result.dart';
import '../theme/app_theme.dart';
import '../providers.dart';
import 'desktop.dart';

/// "¿Letra equivocada?": deja corregir título/artista y elegir a mano entre
/// todos los resultados de LRCLIB. Devuelve la letra elegida (o `null`).
Future<LyricsResult?> showLyricsPicker(
  BuildContext context, {
  required String title,
  required String artist,
  int? durationSeconds,
}) {
  return showAdaptiveSheet<LyricsResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LyricsPicker(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    ),
  );
}

class _LyricsPicker extends ConsumerStatefulWidget {
  final String title;
  final String artist;
  final int? durationSeconds;

  const _LyricsPicker({required this.title, required this.artist, this.durationSeconds});

  @override
  ConsumerState<_LyricsPicker> createState() => _LyricsPickerState();
}

class _LyricsPickerState extends ConsumerState<_LyricsPicker> {
  late final _service = ref.read(lrclibProvider);
  late final _titleController = TextEditingController(text: widget.title);
  late final _artistController = TextEditingController(text: widget.artist);
  List<LyricsResult> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final title = _titleController.text.trim();
      final artist = _artistController.text.trim();
      final lists = await Future.wait([
        _service.search(trackName: title, artistName: artist).catchError((_) => <LyricsResult>[]),
        _service.searchGeneral('$title $artist').catchError((_) => <LyricsResult>[]),
      ]);
      final seen = <String>{};
      final merged = <LyricsResult>[];
      for (final r in [...lists[0], ...lists[1]]) {
        final key = '${r.song.title}|${r.song.artist}|${r.song.durationSeconds}|${r.hasSyncedLyrics}';
        if (seen.add(key) && (r.hasSyncedLyrics || r.plainLyrics.trim().isNotEmpty)) {
          merged.add(r);
        }
      }
      // Primero las sincronizadas y las de duración más parecida.
      final target = widget.durationSeconds;
      merged.sort((a, b) {
        final s = (b.hasSyncedLyrics ? 1 : 0).compareTo(a.hasSyncedLyrics ? 1 : 0);
        if (s != 0 || target == null) return s;
        final da = ((a.song.durationSeconds ?? 9999) - target).abs();
        final db = ((b.song.durationSeconds ?? 9999) - target).abs();
        return da.compareTo(db);
      });
      if (mounted) setState(() => _results = merged);
    } catch (e) {
      if (mounted) setState(() => _error = 'No se pudo buscar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int? seconds) {
    if (seconds == null) return '';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              const Center(child: SheetHandle()),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Text(
                  'Elegir otra letra',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _titleController,
                        decoration: const InputDecoration(hintText: 'Título', isDense: true),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _artistController,
                        decoration: const InputDecoration(hintText: 'Artista', isDense: true),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      onPressed: _loading ? null : _search,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _error != null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!, textAlign: TextAlign.center),
                          )
                        : _results.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(32),
                                child: Text(
                                  'Sin resultados. Prueba corrigiendo el título o el artista.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: AppTheme.textSecondary),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: _results.length,
                                itemBuilder: (context, i) {
                                  final r = _results[i];
                                  final preview = (r.hasSyncedLyrics
                                          ? r.syncedLyrics
                                              .map((l) => l.text)
                                              .where((t) => t.trim().isNotEmpty)
                                              .take(2)
                                              .join(' / ')
                                          : r.plainLyrics.split('\n').take(2).join(' / '))
                                      .trim();
                                  return ListTile(
                                    title: Text(
                                      r.song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      [
                                        r.song.artist,
                                        if (r.song.album != null && r.song.album!.isNotEmpty)
                                          r.song.album!,
                                        _fmt(r.song.durationSeconds),
                                        if (preview.isNotEmpty) '\n$preview',
                                      ].where((e) => e.isNotEmpty).join(' · '),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppTheme.textSecondary),
                                    ),
                                    trailing: Icon(
                                      r.hasSyncedLyrics
                                          ? Icons.graphic_eq_rounded
                                          : Icons.notes_rounded,
                                      color: r.hasSyncedLyrics
                                          ? Theme.of(context).colorScheme.primary
                                          : AppTheme.textSecondary,
                                    ),
                                    onTap: () => Navigator.pop(context, r),
                                  );
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
