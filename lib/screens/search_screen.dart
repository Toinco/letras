import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../services/history_service.dart';
import '../services/lrclib_service.dart';
import '../services/lyrics_storage_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/album_card.dart';
import '../widgets/artist_card.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_card.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'lyrics_screen.dart';
import 'settings_screen.dart';
import '../providers.dart';
import '../widgets/desktop.dart';
import '../widgets/empty_state.dart';

/// Buscador con 3 pestañas: Canciones, Álbumes y Artistas — un solo campo
/// de texto dispara las tres búsquedas (más la búsqueda entre tus letras
/// ya descargadas) en paralelo.
///
/// En Canciones se puede además "Seleccionar" varias de los resultados
/// online y descargarlas todas juntas de una.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late final _lrclibService = ref.read(lrclibProvider);
  late final _storage = ref.read(storageProvider);
  late final _translationService = ref.read(translationProvider);
  late final _artworkService = ref.read(artworkProvider);
  late final _catalogService = ref.read(catalogProvider);
  final _queryController = TextEditingController();
  late final _historyService = ref.read(historyProvider);
  Timer? _typingDebounce;
  // Evita que una búsqueda vieja (más lenta) pise los resultados de una
  // más nueva cuando se busca mientras se escribe.
  int _searchToken = 0;
  List<Song> _history = [];

  List<LyricsResult> _localResults = [];
  // Para cada letra local, en qué línea aparece lo buscado (si fue por letra).
  Map<String, LyricsSearchHit> _localHits = {};
  List<LyricsResult> _onlineResults = [];
  // Versiones repetidas de LRCLIB agrupadas bajo la mejor de cada canción.
  Map<String, List<LyricsResult>> _versions = {};
  String _lastQuery = '';
  List<AlbumResult> _albumResults = [];
  List<ArtistResult> _artistResults = [];

  bool _loading = false;
  bool _searched = false;

  // --- Selección múltiple (solo para los resultados online de Canciones,
  // que son los que todavía no están descargados) ---
  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};
  bool _bulkDownloading = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;

  String _keyFor(LyricsResult r) =>
      '${r.song.artist.toLowerCase().trim()}|||${r.song.title.toLowerCase().trim()}';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // La barra de selección múltiple solo tiene sentido en la pestaña
    // Canciones: hay que refrescar el Scaffold cuando se cambia de
    // pestaña (con un tap o deslizando) para que aparezca/desaparezca.
    _tabController.addListener(_onTabChanged);
    HistoryService.changes.addListener(_loadHistory);
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await _historyService.list();
    if (mounted) setState(() => _history = history);
  }

  void _onQueryChanged(String value) {
    _typingDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _searched = false);
      return;
    }
    if (value.trim().length < 3) return;
    _typingDebounce = Timer(const Duration(milliseconds: 600), () => _search(unfocus: false));
  }

  Future<void> _openFromHistory(Song song) async {
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
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró la letra de esta canción.')),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LyricsScreen(result: result, originalSong: song)),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error buscando la letra: $e')),
      );
    }
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return const EmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Busca cualquier canción',
        message: 'Por título, álbum o artista. Pegar un pedazo de la letra también '
            'busca entre tus letras ya descargadas.',
      );
    }
    return ListView(
      children: [
        Row(
          children: [
            Expanded(child: _sectionHeader('RECIENTES')),
            TextButton(
              onPressed: () => _historyService.clear(),
              child: const Text('Borrar'),
            ),
          ],
        ),
        for (final song in _history)
          SongCard(
            song: song,
            trailing: const Icon(Icons.history_rounded, size: 18, color: AppTheme.textSecondary),
            onTap: () => _openFromHistory(song),
          ),
        const SizedBox(height: 40),
      ],
    );
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    HistoryService.changes.removeListener(_loadHistory);
    _typingDebounce?.cancel();
    _tabController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  bool _sameSong(LyricsResult a, LyricsResult b) =>
      a.song.title.toLowerCase().trim() == b.song.title.toLowerCase().trim() &&
      a.song.artist.toLowerCase().trim() == b.song.artist.toLowerCase().trim();

  Future<void> _search({bool unfocus = true}) async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    _typingDebounce?.cancel();
    final token = ++_searchToken;
    if (unfocus) FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _searched = true;
      _selectionMode = false;
      _selectedKeys.clear();
    });

    // Las 4 búsquedas (letras ya descargadas, letras online, álbumes,
    // artistas) salen todas en paralelo: antes álbumes/artistas ni
    // existían, y local/online ya iban una después de la otra. Ahora todo
    // tarda lo que tarda la más lenta de las 4, no la suma.
    final results = await Future.wait<dynamic>([
      _storage.searchInLyrics(query),
      _lrclibService.searchGeneral(query).catchError((_) => <LyricsResult>[]),
      _catalogService.searchAlbums(query),
      _catalogService.searchArtists(query),
    ]);

    final hits = results[0] as List<LyricsSearchHit>;
    final local = hits.map((h) => h.result).toList();
    var online = results[1] as List<LyricsResult>;
    final albums = results[2] as List<AlbumResult>;
    final artists = results[3] as List<ArtistResult>;

    // No repetir en "Resultados" lo que ya aparece en "Tus descargas".
    online = online.where((r) => !local.any((l) => _sameSong(l, r))).toList();
    // LRCLIB devuelve la misma canción subida varias veces: mostramos una
    // sola (la mejor sincronizada) con "N versiones".
    final groups = LrclibService.groupVersions(online);

    if (!mounted || token != _searchToken) return;
    setState(() {
      _lastQuery = query;
      _localResults = local;
      _localHits = {for (final h in hits) _keyFor(h.result): h};
      _onlineResults = groups.map((g) => g.best).toList();
      _versions = {for (final g in groups) _keyFor(g.best): g.versions};
      _albumResults = albums;
      _artistResults = artists;
      _loading = false;
    });
  }

  /// Descarga una sola letra (con traducción y carátula en paralelo) y
  /// devuelve la versión guardada, o `null` si falló.
  Future<LyricsResult?> _downloadSingleResult(LyricsResult result) async {
    try {
      final needsTranslation = result.translatedLines == null && result.hasSyncedLyrics;
      final fetches = await Future.wait<dynamic>([
        needsTranslation
            ? _translationService
                .translate(result.syncedLyrics.map((l) => l.text).toList())
            : Future.value(result.translatedLines),
        _artworkService.fetchArtworkBytes(
          result.song.title,
          result.song.artist,
          knownUrl: result.song.artworkUrl,
        ),
      ]);
      final translated = fetches[0] as List<String>?;
      final artwork = fetches[1] as Uint8List?;
      final saved = result.copyWith(translatedLines: translated, translationLang: SettingsService.translationLang.value);
      await _storage.save(saved, artworkBytes: artwork);
      return saved;
    } catch (_) {
      return null;
    }
  }

  Future<void> _download(LyricsResult result) async {
    final saved = await _downloadSingleResult(result);
    if (!mounted) return;
    if (saved != null) {
      setState(() {
        _onlineResults.removeWhere((r) => _sameSong(r, result));
        _localResults = [..._localResults, saved];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Letra descargada. Ya la puedes ver sin conexión.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo descargar esta letra.')),
      );
    }
  }

  /// Descarga todas las canciones tildadas, varias en paralelo (no una por
  /// una): la selección múltiple que se pidió para "elegir qué letras
  /// descargar a mano".
  Future<void> _downloadSelected() async {
    final toDownload = _onlineResults.where((r) => _selectedKeys.contains(_keyFor(r))).toList();
    if (toDownload.isEmpty) return;

    setState(() {
      _bulkDownloading = true;
      _bulkDone = 0;
      _bulkTotal = toDownload.length;
    });

    final saved = <LyricsResult>[];
    var nextIndex = 0;
    var done = 0;
    final workerCount = toDownload.length < 4 ? toDownload.length : 4;

    Future<void> worker() async {
      while (true) {
        final i = nextIndex;
        if (i >= toDownload.length) return;
        nextIndex++;
        final result = await _downloadSingleResult(toDownload[i]);
        if (result != null) saved.add(result);
        done++;
        if (mounted) setState(() => _bulkDone = done);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));

    if (!mounted) return;
    setState(() {
      _bulkDownloading = false;
      _selectionMode = false;
      _selectedKeys.clear();
      _onlineResults.removeWhere((r) => saved.any((s) => _sameSong(s, r)));
      _localResults = [..._localResults, ...saved];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Se descargaron ${saved.length} letras.')),
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedKeys.clear();
    });
  }

  void _toggleSelected(LyricsResult r) {
    final key = _keyFor(r);
    setState(() {
      if (!_selectedKeys.remove(key)) _selectedKeys.add(key);
    });
  }

  void _enterSelectionWith(LyricsResult r) {
    setState(() {
      _selectionMode = true;
      _selectedKeys.add(_keyFor(r));
    });
  }

  /// Elegir entre las distintas subidas a LRCLIB de la misma canción.
  void _showVersions(LyricsResult best) {
    final versions = _versions[_keyFor(best)] ?? [best];
    String fmt(int? s) => s == null ? '' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    showAdaptiveSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                '${versions.length} versiones de "${best.song.title}"',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final v in versions)
              ListTile(
                leading: Icon(
                  v.hasWordSync
                      ? Icons.auto_awesome_rounded
                      : v.hasSyncedLyrics
                          ? Icons.graphic_eq_rounded
                          : Icons.notes_rounded,
                  color: v.hasSyncedLyrics
                      ? Theme.of(context).colorScheme.primary
                      : AppTheme.textSecondary,
                ),
                title: Text(v.song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if ((v.song.album ?? '').isNotEmpty) v.song.album!,
                    if (v.song.durationSeconds != null) fmt(v.song.durationSeconds),
                    v.hasWordSync
                        ? 'por palabra'
                        : (v.hasSyncedLyrics ? 'sincronizada' : 'sin sincronizar'),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openResult(v, alreadySaved: false);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openResult(LyricsResult result, {required bool alreadySaved, String? highlight}) {
    showSongActionsSheet(
      context,
      song: result.song,
      onViewLyrics: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LyricsScreen(result: result, highlightQuery: highlight),
          ),
        );
      },
      onDownload: alreadySaved ? null : () => _download(result),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _buildSongsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final hasResults = _localResults.isNotEmpty || _onlineResults.isNotEmpty;
    if (!hasResults) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No se encontraron canciones',
        message: 'Prueba con menos palabras o solo con el título.',
      );
    }
    return Column(
      children: [
        if (_onlineResults.isNotEmpty)
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _toggleSelectionMode,
                child: Text(_selectionMode ? 'Cancelar' : 'Seleccionar'),
              ),
            ],
          ),
        Expanded(
          child: ListView(
            children: [
              if (_localResults.isNotEmpty) ...[
                _sectionHeader('EN TUS DESCARGAS'),
                for (final result in _localResults)
                  Builder(builder: (context) {
                    final hit = _localHits[_keyFor(result)];
                    final line = hit?.lineText;
                    return SongCard(
                      song: result.song,
                      // Si coincidió dentro de la letra, mostramos esa línea.
                      subtitleOverride: line == null ? null : '"${line.trim()}"',
                      trailing: Icon(Icons.download_done_rounded,
                          size: 18, color: Theme.of(context).colorScheme.primary),
                      onTap: () => _openResult(
                        result,
                        alreadySaved: true,
                        highlight: line == null ? null : _lastQuery,
                      ),
                    );
                  }),
              ],
              if (_onlineResults.isNotEmpty) ...[
                _sectionHeader('RESULTADOS'),
                for (final result in _onlineResults)
                  SongCard(
                    song: result.song,
                    selectionMode: _selectionMode,
                    selected: _selectedKeys.contains(_keyFor(result)),
                    subtitleOverride: (_versions[_keyFor(result)]?.length ?? 1) > 1
                        ? '${result.song.artist} · ${_versions[_keyFor(result)]!.length} versiones'
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (result.hasSyncedLyrics)
                          Icon(
                            result.hasWordSync ? Icons.auto_awesome_rounded : Icons.graphic_eq_rounded,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        if ((_versions[_keyFor(result)]?.length ?? 1) > 1)
                          IconButton(
                            tooltip: 'Ver versiones',
                            icon: const Icon(Icons.layers_rounded, size: 20),
                            onPressed: () => _showVersions(result),
                          ),
                      ],
                    ),
                    onTap: _selectionMode
                        ? () => _toggleSelected(result)
                        : () => _openResult(result, alreadySaved: false),
                    onLongPress: _selectionMode ? null : () => _enterSelectionWith(result),
                  ),
              ],
              const SizedBox(height: 80),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_albumResults.isEmpty) {
      return const EmptyState(icon: Icons.album_rounded, title: 'No se encontraron álbumes');
    }
    return ListView.builder(
      itemCount: _albumResults.length,
      itemBuilder: (context, index) {
        final album = _albumResults[index];
        return AlbumCard(
          album: album,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AlbumScreen(album: album)),
          ),
        );
      },
    );
  }

  Widget _buildArtistsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_artistResults.isEmpty) {
      return const EmptyState(icon: Icons.person_search_rounded, title: 'No se encontraron artistas');
    }
    return ListView.builder(
      itemCount: _artistResults.length,
      itemBuilder: (context, index) {
        final artist = _artistResults[index];
        return ArtistCard(
          artist: artist,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ArtistScreen(artist: artist)),
          ),
        );
      },
    );
  }

  Widget _buildSelectionBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _bulkDownloading
                    ? 'Descargando $_bulkDone / $_bulkTotal...'
                    : '${_selectedKeys.length} seleccionadas',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            ),
            ElevatedButton(
              onPressed: (_bulkDownloading || _selectedKeys.isEmpty) ? null : _downloadSelected,
              child: _bulkDownloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Descargar seleccionadas'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Buscar'),
          actions: [
            // En pantallas anchas Ajustes está en el menú lateral.
            if (!isWideLayout(context))
              IconButton(
                tooltip: 'Ajustes',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Canciones'),
              Tab(text: 'Álbumes'),
              Tab(text: 'Artistas'),
            ],
          ),
        ),
        bottomNavigationBar:
            (_selectionMode && _tabController.index == 0) ? _buildSelectionBar() : null,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            children: [
              TextField(
                controller: _queryController,
                decoration: const InputDecoration(
                  hintText: 'Título, artista, álbum o parte de la letra',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _search,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Buscar'),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: !_searched
                    ? _buildHistory()
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildSongsTab(),
                          _buildAlbumsTab(),
                          _buildArtistsTab(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
