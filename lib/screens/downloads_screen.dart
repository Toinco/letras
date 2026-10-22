import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lyrics_result.dart';
import '../services/backup_service.dart';
import '../services/lyrics_storage_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../utils/text_normalize.dart';
import '../widgets/playlist_sheet.dart';
import '../widgets/song_card.dart';
import 'lyrics_screen.dart';
import 'playlist_screen.dart';
import 'stats_screen.dart';
import '../providers.dart';
import '../widgets/desktop.dart';
import '../widgets/empty_state.dart';

enum _DownloadsFilterMode { all, album, playlists }

/// Lista de letras descargadas para verlas sin conexión. La lupa busca por
/// título, artista y también adentro de las letras (mostrando la línea
/// donde aparece). Se puede agrupar por álbum o ver las playlists.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  late final _storage = ref.read(storageProvider);
  late final _playlistService = ref.read(playlistProvider);
  final _searchController = TextEditingController();

  List<LyricsResult> _downloads = [];
  List<LyricsPlaylist> _playlists = [];
  // Coincidencias adentro de las letras (clave de la canción -> línea).
  Map<String, LyricsSearchHit> _lyricHits = {};
  Timer? _searchDebounce;
  bool _busy = false;
  bool _loading = true;
  String _query = '';
  _DownloadsFilterMode _mode = _DownloadsFilterMode.all;

  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    LyricsStorageService.changes.addListener(_onStorageChanged);
    PlaylistService.changes.addListener(_loadPlaylists);
    _load();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    final lists = await _playlistService.list();
    if (mounted) setState(() => _playlists = lists);
  }

  String _key(LyricsResult r) => LyricsStorageService.keyFor(r.song.title, r.song.artist);

  void _onQueryChanged(String v) {
    setState(() => _query = v);
    _searchDebounce?.cancel();
    if (normalizeForSearch(v).length < 3) {
      setState(() => _lyricHits = {});
      return;
    }
    // Buscar adentro de las letras es una consulta a la base: esperamos a
    // que se deje de escribir un toque.
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final hits = await _storage.searchInLyrics(v);
      if (!mounted || v != _query) return;
      setState(() => _lyricHits = {
            for (final h in hits)
              if (h.lineIndex != null) _key(h.result): h,
          });
    });
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      await BackupService().exportAndShare();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final summary = await BackupService().pickAndImport();
      if (summary == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Importadas ${summary.lyricsAdded} letras nuevas '
          '(de ${summary.lyricsTotal}), ${summary.playlists} playlists.',
        ),
      ));
      _load(quiet: true);
    } on FormatException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo importar: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newPlaylist() async {
    final name = await askPlaylistName(context);
    if (name == null) return;
    await _playlistService.create(name);
  }

  void _onStorageChanged() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 600), () => _load(quiet: true));
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    // Antes de listar, sacamos duplicados (la misma canción guardada más
    // de una vez por pequeñas variaciones de título/artista).
    final removed = await _storage.removeDuplicates();
    final downloads = await _storage.listAll();
    if (mounted) {
      setState(() {
        // El índice está en orden de descarga: mostramos lo último primero.
        _downloads = downloads.reversed.toList();
        _loading = false;
      });
      if (removed > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(removed == 1
                ? 'Se eliminó 1 letra repetida.'
                : 'Se eliminaron $removed letras repetidas.'),
          ),
        );
      }
    }
  }

  Future<void> _delete(LyricsResult result) async {
    // Guardamos la carátula antes de borrar, para poder deshacer.
    final art = await _storage.getArtworkBytes(result.song.title, result.song.artist);
    await _storage.remove(result.song.title, result.song.artist);
    if (!mounted) return;
    setState(() => _downloads.removeWhere(
        (r) => r.song.title == result.song.title && r.song.artist == result.song.artist));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Se borró "${result.song.title}".'),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () async {
            await _storage.save(result, artworkBytes: art);
            _load();
          },
        ),
      ));
  }

  List<LyricsResult> get _filtered {
    if (_query.trim().isEmpty) return _downloads;
    final q = normalizeForSearch(_query);
    return _downloads.where((r) {
      return normalizeForSearch(r.song.title).contains(q) ||
          normalizeForSearch(r.song.artist).contains(q) ||
          _lyricHits.containsKey(_key(r));
    }).toList();
  }

  /// Agrupa por álbum (las que no tengan álbum guardado van todas juntas al
  /// final), ordenado alfabéticamente.
  List<MapEntry<String, List<LyricsResult>>> get _groupedByAlbum {
    final groups = <String, List<LyricsResult>>{};
    for (final r in _filtered) {
      final album = (r.song.album == null || r.song.album!.trim().isEmpty)
          ? 'Sin álbum'
          : r.song.album!.trim();
      groups.putIfAbsent(album, () => []).add(r);
    }
    // Dentro de cada álbum, si tenemos el número de pista (por ejemplo,
    // canciones bajadas desde la pantalla de Álbum), las ordenamos como
    // en el álbum original en vez de por el orden en que se descargaron.
    for (final list in groups.values) {
      list.sort((a, b) {
        final ta = a.song.trackNumber;
        final tb = b.song.trackNumber;
        if (ta != null && tb != null) return ta.compareTo(tb);
        if (ta != null) return -1;
        if (tb != null) return 1;
        return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
      });
    }
    final entries = groups.entries.toList()
      ..sort((a, b) {
        if (a.key == 'Sin álbum') return 1;
        if (b.key == 'Sin álbum') return -1;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    return entries;
  }

  Widget _buildSongTile(LyricsResult result) {
    final hit = _query.trim().isEmpty ? null : _lyricHits[_key(result)];
    final titleMatch = normalizeForSearch(result.song.title).contains(normalizeForSearch(_query)) ||
        normalizeForSearch(result.song.artist).contains(normalizeForSearch(_query));
    final showLine = hit != null && !titleMatch;
    return SongCard(
      song: result.song,
      subtitleOverride: showLine ? '"${hit.lineText!.trim()}"' : null,
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
        onSelected: (v) {
          if (v == 'playlist') showAddToPlaylistSheet(context, result);
          if (v == 'delete') _delete(result);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'playlist', child: Text('Agregar a playlist')),
          PopupMenuItem(value: 'delete', child: Text('Borrar')),
        ],
      ),
      onLongPress: () => showAddToPlaylistSheet(context, result),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LyricsScreen(
              result: result,
              // Si se encontró adentro de la letra, se abre con esa línea
              // resaltada.
              highlightQuery: showLine ? _query : null,
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylists() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor: AppTheme.surface,
            child: Icon(Icons.add_rounded, color: Theme.of(context).colorScheme.primary),
          ),
          title: const Text('Nueva playlist'),
          onTap: _newPlaylist,
        ),
        for (final p in _playlists)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(
              backgroundColor: AppTheme.surface,
              child: Icon(Icons.queue_music_rounded, color: Colors.white70),
            ),
            title: Text(p.name),
            subtitle: Text(
              p.count == 1 ? '1 letra' : '${p.count} letras',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: p)),
            ),
          ),
        if (_playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text(
              'Mantén apretada una letra para agregarla a una playlist.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    LyricsStorageService.changes.removeListener(_onStorageChanged);
    PlaylistService.changes.removeListener(_loadPlaylists);
    _reloadDebounce?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Descargas'),
          actions: [
            IconButton(
              tooltip: 'Estadísticas',
              icon: const Icon(Icons.insights_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StatsScreen()),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'export') _export();
                  if (v == 'import') _import();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'export', child: Text('Exportar todo (ZIP)')),
                  PopupMenuItem(value: 'import', child: Text('Importar desde ZIP')),
                ],
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _downloads.isEmpty
                ? EmptyState(
                    icon: Icons.download_rounded,
                    title: 'Todavía no hay descargas',
                    message: 'Las letras que descargues se ven sin conexión, con su '
                        'traducción. Toca el ícono de descarga mientras suena una canción.',
                    action: TextButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.unarchive_rounded),
                      label: const Text('Importar una copia de seguridad'),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                        child: TextField(
                          controller: _searchController,
                          onChanged: _onQueryChanged,
                          decoration: InputDecoration(
                            hintText: 'Título, artista o parte de la letra',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () {
                                      _searchController.clear();
                                      _onQueryChanged('');
                                    },
                                  ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('Todo'),
                              selected: _mode == _DownloadsFilterMode.all,
                              onSelected: (_) =>
                                  setState(() => _mode = _DownloadsFilterMode.all),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Por álbum'),
                              selected: _mode == _DownloadsFilterMode.album,
                              onSelected: (_) =>
                                  setState(() => _mode = _DownloadsFilterMode.album),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Playlists'),
                              selected: _mode == _DownloadsFilterMode.playlists,
                              onSelected: (_) =>
                                  setState(() => _mode = _DownloadsFilterMode.playlists),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: _mode == _DownloadsFilterMode.playlists
                              ? _buildPlaylists()
                              : _filtered.isEmpty
                              ? ListView(
                                  children: const [
                                    Padding(
                                      padding: EdgeInsets.only(top: 60),
                                      child: Center(
                                        child: Text(
                                          'No se encontraron letras con ese filtro.',
                                          style: TextStyle(color: AppTheme.textSecondary),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : _mode == _DownloadsFilterMode.all
                                  ? ListView.builder(
                                      padding: const EdgeInsets.symmetric(horizontal: 20),
                                      itemCount: _filtered.length,
                                      itemBuilder: (context, index) =>
                                          _buildSongTile(_filtered[index]),
                                    )
                                  : ListView(
                                      padding: const EdgeInsets.symmetric(horizontal: 20),
                                      children: [
                                        for (final group in _groupedByAlbum) ...[
                                          Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            child: Text(
                                              group.key.toUpperCase(),
                                              style: const TextStyle(
                                                color: AppTheme.textSecondary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                          for (final result in group.value)
                                            _buildSongTile(result),
                                        ],
                                      ],
                                    ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
