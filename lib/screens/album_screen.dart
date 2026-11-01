import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/itunes_catalog_service.dart';
import '../theme/app_theme.dart';
import '../widgets/apple_ui.dart';
import '../widgets/cached_artwork.dart';
import '../widgets/desktop.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_play.dart';
import 'lyrics_screen.dart';

/// Página de un álbum al estilo Apple Music: tapa grande, título, artista
/// (se toca para ir a su página), género y año, Reproducir / Aleatorio, las
/// canciones numeradas con su duración (la que está sonando, marcada), la
/// fecha y duración total al pie, y más álbumes del artista.
///
/// Tocar una canción la pone a sonar con el resto del álbum detrás; en
/// "más" están la letra y el otro servicio. Arriba a la derecha se pueden
/// descargar las letras de todo el álbum.
class AlbumScreen extends ConsumerStatefulWidget {
  final AlbumResult album;

  const AlbumScreen({super.key, required this.album});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  late final _catalog = ref.read(catalogProvider);
  late final _storage = ref.read(storageProvider);
  late final _downloadHelper = ref.read(downloadHelperProvider);

  AlbumDetails? _details;
  List<Song> get _tracks => _details?.tracks ?? const [];
  List<AlbumResult> _moreByArtist = [];
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
    final details = await _catalog.getAlbumDetails(widget.album.collectionId);
    if (!mounted) return;
    setState(() {
      _details = details;
      _loading = false;
      _error = (details == null || details.tracks.isEmpty)
          ? 'No se pudo cargar el listado de canciones.'
          : null;
    });
    final artistId = details?.artistId;
    if (artistId != null) {
      final albums = await _catalog.getArtistAlbums(artistId);
      if (!mounted) return;
      setState(() {
        _moreByArtist =
            albums.where((a) => a.collectionId != widget.album.collectionId).take(15).toList();
      });
    }
  }

  Future<void> _openLyrics(Song song) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final saved = await _storage.getSaved(song.title, song.artist);
      final result = saved ??
          await ref
              .read(lyricsFinderProvider)
              .find(song.title, song.artist, durationSeconds: song.durationSeconds);
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

  void _openTrackSheet(Song track, int index) {
    showSongActionsSheet(
      context,
      song: track,
      leadingActions: playSheetActions(context, track, upNext: _tracks.sublist(index + 1)),
      onViewLyrics: () => _openLyrics(track),
    );
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

  static const _months = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', //
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];

  String? get _releaseText {
    final raw = _details?.releaseDate ?? widget.album.releaseDate;
    final d = raw == null ? null : DateTime.tryParse(raw);
    if (d == null) return null;
    return '${d.day} de ${_months[d.month - 1]} de ${d.year}';
  }

  String get _footer {
    final count = _tracks.length;
    final minutes = (_details?.totalDuration ?? Duration.zero).inMinutes;
    final parts = [
      count == 1 ? '1 canción' : '$count canciones',
      if (minutes > 0) minutes >= 60 ? '${minutes ~/ 60} h ${minutes % 60} min' : '$minutes minutos',
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return ReadableFrame(
      maxWidth: 900,
      child: Scaffold(
        appBar: AppBar(
          actions: [
            if (!_bulkRunning)
              IconButton(
                tooltip: 'Descargar las letras del álbum',
                icon: const Icon(Icons.download_for_offline_outlined),
                onPressed: _tracks.isEmpty ? null : _downloadAll,
              ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 680;
            return ListView(
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                if (wide) _wideHeader(album) else _narrowHeader(album, constraints.maxWidth),
                const SizedBox(height: 18),
                if (_bulkRunning) _bulkProgress(),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                  )
                else ...[
                  for (var i = 0; i < _tracks.length; i++) _trackRow(i),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_releaseText != null) _footnote(_releaseText!),
                        _footnote(_footer),
                        if (_details?.copyright != null) _footnote(_details!.copyright!),
                      ],
                    ),
                  ),
                ],
                if (_moreByArtist.isNotEmpty) ...[
                  const SizedBox(height: 30),
                  SectionHeader(title: 'Más de ${album.artist}'),
                  const SizedBox(height: 10),
                  AlbumCardRow(albums: _moreByArtist, size: wide ? 170 : 140),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _footnote(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(text, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );

  /// Género · año (y "Explícito").
  String get _meta => [
        if (_details?.genre != null) _details!.genre!.toUpperCase(),
        if (widget.album.releaseYear != null) '${widget.album.releaseYear}',
      ].join(' · ');

  Widget _artistLink(String name, {TextAlign align = TextAlign.center}) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: () => openArtistNamed(context, name),
      child: Text(
        name,
        textAlign: align,
        style: TextStyle(color: accent, fontSize: 19, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _cover(AlbumResult album, double size) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 14))],
        ),
        child: CachedArtwork(
          url: album.artworkUrl,
          size: size,
          borderRadius: 12,
          fallbackIcon: Icons.album_rounded,
        ),
      );

  Widget _narrowHeader(AlbumResult album, double width) {
    final size = (width * 0.66).clamp(180.0, 300.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 4),
          _cover(album, size),
          const SizedBox(height: 18),
          Text(
            album.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
          const SizedBox(height: 2),
          _artistLink(album.artist),
          if (_meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(_meta, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          PlayShuffleButtons(songs: _tracks, padding: EdgeInsets.zero),
        ],
      ),
    );
  }

  /// En la compu: tapa a la izquierda y los datos a la derecha (como Música
  /// en la Mac).
  Widget _wideHeader(AlbumResult album) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _cover(album, 250),
          const SizedBox(width: 26),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.title,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                _artistLink(album.artist, align: TextAlign.left),
                if (_meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_meta, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: 360,
                  child: PlayShuffleButtons(songs: _tracks, padding: EdgeInsets.zero),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulkProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: _bulkTotal > 0 ? _bulkDone / _bulkTotal : null,
              backgroundColor: AppTheme.surface,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Letras $_bulkDone / $_bulkTotal',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          TextButton(
            onPressed: () => setState(() => _bulkCancelled = true),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  static String _duration(int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _trackRow(int i) {
    final t = _tracks[i];
    final now = ref.watch(nowPlayingControllerProvider.select((c) => c.track));
    final playingThis = now != null &&
        now.title.toLowerCase().trim() == t.title.toLowerCase().trim() &&
        now.artist.toLowerCase().contains(t.artist.split(',').first.toLowerCase().trim());
    final accent = Theme.of(context).colorScheme.primary;
    // Si el artista de la canción es otro (un invitado), se muestra debajo.
    final showArtist = t.artist.trim().toLowerCase() != widget.album.artist.trim().toLowerCase();
    return InkWell(
      onTap: () => playSong(context, t, upNext: _tracks.sublist(i + 1)),
      onLongPress: () => _openTrackSheet(t, i),
      onSecondaryTap: () => _openTrackSheet(t, i),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: playingThis
                  ? Icon(
                      now.isPlaying ? Icons.graphic_eq_rounded : Icons.pause_rounded,
                      color: accent,
                      size: 18,
                    )
                  : Text(
                      '${t.trackNumber ?? i + 1}',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15),
                    ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              color: playingThis ? accent : Colors.white,
                              fontWeight: playingThis ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          if (showArtist)
                            Text(
                              t.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      _duration(t.durationSeconds),
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    ),
                    IconButton(
                      tooltip: 'Más',
                      icon: const Icon(Icons.more_horiz_rounded, color: AppTheme.textSecondary),
                      onPressed: () => _openTrackSheet(t, i),
                    ),
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
