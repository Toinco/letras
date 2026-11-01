import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/discovery_service.dart';
import '../widgets/apple_ui.dart';
import '../widgets/cached_artwork.dart';
import 'song_list_screen.dart';
import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../services/history_service.dart';
import '../services/lrclib_service.dart';
import '../services/lyrics_storage_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_card.dart';
import '../widgets/song_play.dart';
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
  // Canciones del catálogo (se reproducen al tocarlas).
  List<Song> _catalogSongs = [];

  // Pestañas: Todo, Canciones, Álbumes, Artistas, Letras.
  static const _lyricsTab = 4;

  bool _loading = false;
  // Las letras de internet llegan después que el resto.
  bool _lyricsLoading = false;
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
    _tabController = TabController(length: 5, vsync: this);
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

    // Todo sale en paralelo. El catálogo (canciones, álbumes, artistas) y
    // tus letras descargadas se muestran apenas llegan; las letras de
    // internet (LRCLIB, que a veces anda lento) se suman después, sin
    // hacer esperar al resto.
    _lyricsLoading = true;
    final onlineFuture =
        _lrclibService.searchGeneral(query).catchError((_) => <LyricsResult>[]);
    final results = await Future.wait<dynamic>([
      _storage.searchInLyrics(query),
      _catalogService.searchAlbums(query),
      _catalogService.searchArtists(query),
      _catalogService.searchSongs(query, limit: 25),
    ]);

    final hits = results[0] as List<LyricsSearchHit>;
    final local = hits.map((h) => h.result).toList();
    if (!mounted || token != _searchToken) return;
    setState(() {
      _lastQuery = query;
      _localResults = local;
      _localHits = {for (final h in hits) _keyFor(h.result): h};
      _onlineResults = [];
      _versions = {};
      _albumResults = results[1] as List<AlbumResult>;
      _artistResults = results[2] as List<ArtistResult>;
      _catalogSongs = results[3] as List<Song>;
      _loading = false;
    });

    var online = await onlineFuture;
    // No repetir en "Resultados" lo que ya aparece en "Tus descargas".
    online = online.where((r) => !local.any((l) => _sameSong(l, r))).toList();
    // LRCLIB devuelve la misma canción subida varias veces: mostramos una
    // sola (la mejor sincronizada) con "N versiones".
    final groups = LrclibService.groupVersions(online);
    if (!mounted || token != _searchToken) return;
    setState(() {
      _onlineResults = groups.map((g) => g.best).toList();
      _versions = {for (final g in groups) _keyFor(g.best): g.versions};
      _lyricsLoading = false;
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
          album: result.song.album,
          durationSeconds: result.song.durationSeconds,
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
      leadingActions: playSheetActions(context, result.song),
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
    if (_loading || (_lyricsLoading && _localResults.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
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
    if (_loading && _albumResults.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_albumResults.isEmpty) {
      return const EmptyState(icon: Icons.album_rounded, title: 'No se encontraron álbumes');
    }
    // Cuadrícula de tapas, como en Apple Music.
    return LayoutBuilder(builder: (context, constraints) {
      final columns = (constraints.maxWidth / 190).floor().clamp(2, 5);
      final size = (constraints.maxWidth - 40 - (columns - 1) * 14) / columns;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 140),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 14,
          mainAxisSpacing: 16,
          childAspectRatio: size / (size + 46),
        ),
        itemCount: _albumResults.length,
        itemBuilder: (context, i) {
          final a = _albumResults[i];
          return GestureDetector(
            onTap: () => _openAlbum(a),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CachedArtwork(url: a.artworkUrl, size: size, borderRadius: 10),
                const SizedBox(height: 6),
                Text(
                  a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                Text(
                  [a.artist, if (a.releaseYear != null) '${a.releaseYear}'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
              ],
            ),
          );
        },
      );
    });
  }

  Widget _buildArtistsTab() {
    if (_loading && _artistResults.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_artistResults.isEmpty) {
      return const EmptyState(icon: Icons.person_search_rounded, title: 'No se encontraron artistas');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 140),
      itemCount: _artistResults.length,
      itemBuilder: (context, index) {
        final artist = _artistResults[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
          leading: _ArtistPhoto(name: artist.name, size: 52),
          title: Text(artist.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: artist.genre == null
              ? null
              : Text(artist.genre!, style: const TextStyle(color: AppTheme.textSecondary)),
          trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
          onTap: () => _openArtist(artist),
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
        bottomNavigationBar:
            (_selectionMode && _tabController.index == _lyricsTab) ? _buildSelectionBar() : null,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Buscar',
                        style: TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                      ),
                    ),
                    // En pantallas anchas Ajustes está en el menú lateral.
                    if (!isWideLayout(context))
                      IconButton(
                        tooltip: 'Ajustes',
                        icon: const Icon(Icons.settings_rounded, color: AppTheme.textSecondary),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SettingsScreen()),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _queryController,
                  builder: (context, value, _) => TextField(
                    controller: _queryController,
                    decoration: InputDecoration(
                      hintText: 'Artistas, canciones, álbumes o letra',
                      prefixIcon: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : const Icon(Icons.search_rounded),
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Borrar',
                              icon: const Icon(Icons.cancel_rounded, color: AppTheme.textSecondary),
                              onPressed: () {
                                _queryController.clear();
                                setState(() => _searched = false);
                              },
                            ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: _onQueryChanged,
                    onSubmitted: (_) => _search(),
                  ),
                ),
              ),
              if (_searched)
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(text: 'Todo'),
                    Tab(text: 'Canciones'),
                    Tab(text: 'Álbumes'),
                    Tab(text: 'Artistas'),
                    Tab(text: 'Letras'),
                  ],
                ),
              const SizedBox(height: 6),
              Expanded(
                child: !_searched
                    ? _buildBrowse()
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildAllTab(),
                          _buildCatalogSongsTab(),
                          _buildAlbumsTab(),
                          _buildArtistsTab(),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: _buildSongsTab(),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------ sin buscar: explorar

  // Nombre, color y qué lista buscar para cada categoría.
  static const _genres = [
    ('Pop', Color(0xFFFC3C44), 'pop hits'),
    ('Reggaetón', Color(0xFFFF9500), 'reggaeton hits'),
    ('Trap', Color(0xFF5E5CE6), 'trap latino'),
    ('Rock en español', Color(0xFF30B0C7), 'rock en español'),
    ('Cumbia', Color(0xFF34C759), 'cumbia'),
    ('Indie', Color(0xFFAF52DE), 'indie hits'),
    ('Electrónica', Color(0xFF0A84FF), 'electronic hits'),
    ('Hip hop', Color(0xFFFF375F), 'hip hop hits'),
    ('Rock', Color(0xFF8E8E93), 'rock classics'),
    ('R&B', Color(0xFFBF5AF2), 'r&b hits'),
  ];

  /// Abre la lista de una categoría (canciones que se reproducen al tocarlas).
  Future<void> _openGenre(String name, String query) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final songs = await ref.read(discoveryProvider).playlistSongs(query);
    navigator.pop();
    if (songs.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No se pudo cargar esta categoría.')));
      return;
    }
    navigator.push(MaterialPageRoute(
      builder: (_) => SongListScreen(title: name, subtitle: 'Explorar', songs: songs),
    ));
  }

  /// Antes de buscar: lo último que abriste y categorías para explorar,
  /// como Spotify y Apple Music.
  Widget _buildBrowse() {
    final wide = MediaQuery.sizeOf(context).width > 700;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 140),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Recientes',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(onPressed: () => _historyService.clear(), child: const Text('Borrar')),
            ],
          ),
          for (final song in _history.take(6))
            SongCard(
              song: song,
              trailing: IconButton(
                tooltip: 'Reproducir',
                icon: const Icon(Icons.play_circle_fill_rounded, size: 30),
                onPressed: () => playSong(context, song),
              ),
              onTap: () => _openFromHistory(song),
              onLongPress: () => showPlayableSongSheet(context, song),
            ),
          const SizedBox(height: 18),
        ],
        const Text(
          'Explorar categorías',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: wide ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
          children: [
            for (final (name, color, query) in _genres)
              Material(
                color: color,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _openGenre(name, query),
                  child: Stack(
                    children: [
                      Positioned(
                        right: -14,
                        bottom: -14,
                        child: Transform.rotate(
                          angle: 0.4,
                          child: Icon(Icons.music_note_rounded,
                              size: 80, color: Colors.white.withValues(alpha: 0.22)),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          name,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------- resultados

  void _openArtist(ArtistResult artist) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ArtistScreen(artist: artist)),
      );

  void _openAlbum(AlbumResult album) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AlbumScreen(album: album)),
      );

  Widget _catalogSongRow(int i) {
    final song = _catalogSongs[i];
    return SongRow(
      song: song,
      onTap: () => playSong(context, song, upNext: _catalogSongs.sublist(i + 1)),
      onMore: () => showPlayableSongSheet(context, song, upNext: _catalogSongs.sublist(i + 1)),
    );
  }

  Widget _allHeader(String title, int tab) => InkWell(
        onTap: () => _tabController.animateTo(tab),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
          child: Row(
            children: [
              Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
            ],
          ),
        ),
      );

  /// "Todo": el mejor resultado y un poco de cada cosa.
  Widget _buildAllTab() {
    if (_loading && _catalogSongs.isEmpty && _artistResults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final nothing = _catalogSongs.isEmpty &&
        _albumResults.isEmpty &&
        _artistResults.isEmpty &&
        _localResults.isEmpty &&
        _onlineResults.isEmpty;
    if (nothing) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Sin resultados',
        message: 'Prueba con menos palabras o solo con el título.',
      );
    }
    final q = _lastQuery.toLowerCase().trim();
    // El mejor resultado: el artista si se buscó su nombre; si no, la canción.
    final topArtist = _artistResults.where((a) => a.name.toLowerCase().trim() == q).firstOrNull;
    final wide = MediaQuery.sizeOf(context).width > 700;
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        if (topArtist != null || _catalogSongs.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text('Mejor resultado',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
          ),
          _TopResult(
            artist: topArtist,
            song: topArtist == null ? _catalogSongs.first : null,
            onTap: () => topArtist != null
                ? _openArtist(topArtist)
                : playSong(context, _catalogSongs.first, upNext: _catalogSongs.sublist(1)),
          ),
        ],
        if (_catalogSongs.isNotEmpty) ...[
          _allHeader('Canciones', 1),
          for (var i = 0; i < _catalogSongs.length && i < 5; i++) _catalogSongRow(i),
        ],
        if (_artistResults.isNotEmpty) ...[
          _allHeader('Artistas', 3),
          ArtistCircleRow(
            artists: [
              for (final a in _artistResults.take(10)) DiscoveryArtist(name: a.name),
            ],
            size: 96,
          ),
        ],
        if (_albumResults.isNotEmpty) ...[
          _allHeader('Álbumes', 2),
          AlbumCardRow(albums: _albumResults.take(12).toList(), size: wide ? 170 : 140),
        ],
        if (_localResults.isNotEmpty || _onlineResults.isNotEmpty) ...[
          _allHeader('Letras', _lyricsTab),
          for (final r in [..._localResults, ..._onlineResults].take(3))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SongCard(
                song: r.song,
                subtitleOverride: '${r.song.artist} · Letra',
                trailing: Icon(Icons.lyrics_outlined,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                onTap: () => _openResult(r, alreadySaved: _localResults.contains(r)),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildCatalogSongsTab() {
    if (_loading && _catalogSongs.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_catalogSongs.isEmpty) {
      return const EmptyState(icon: Icons.music_off_rounded, title: 'No se encontraron canciones');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 140),
      itemCount: _catalogSongs.length,
      itemBuilder: (context, i) => _catalogSongRow(i),
    );
  }
}

/// La tarjeta grande de "Mejor resultado".
class _TopResult extends StatelessWidget {
  final ArtistResult? artist;
  final Song? song;
  final VoidCallback onTap;

  const _TopResult({this.artist, this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isArtist = artist != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: song == null ? null : () => showPlayableSongSheet(context, song!),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                if (isArtist)
                  _ArtistPhoto(name: artist!.name, size: 84)
                else
                  SongThumb(song: song!, size: 84, radius: 8),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArtist ? artist!.name : song!.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isArtist ? 'Artista' : 'Canción · ${song!.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (!isArtist)
                  Icon(Icons.play_circle_fill_rounded,
                      size: 44, color: Theme.of(context).colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Foto de un artista (de Deezer), redonda.
class _ArtistPhoto extends ConsumerStatefulWidget {
  final String name;
  final double size;

  const _ArtistPhoto({required this.name, required this.size});

  @override
  ConsumerState<_ArtistPhoto> createState() => _ArtistPhotoState();
}

class _ArtistPhotoState extends ConsumerState<_ArtistPhoto> {
  String? _url;

  @override
  void initState() {
    super.initState();
    ref.read(discoveryProvider).artist(widget.name).then((a) {
      if (mounted) setState(() => _url = a?.imageUrl);
    });
  }

  @override
  Widget build(BuildContext context) => CachedArtwork(
        url: _url,
        size: widget.size,
        borderRadius: widget.size / 2,
        fallbackIcon: Icons.person_rounded,
      );
}
