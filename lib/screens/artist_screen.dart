import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album_result.dart';
import '../models/artist_result.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/discovery_service.dart';
import '../theme/app_theme.dart';
import '../widgets/apple_ui.dart';
import '../widgets/cached_artwork.dart';
import '../widgets/song_play.dart';
import '../screens/song_list_screen.dart';
import 'album_screen.dart';

/// Página de un artista al estilo Apple Music: foto grande con el nombre
/// encima y el botón de reproducir, sus canciones principales, el último
/// lanzamiento, álbumes, sencillos y EP, y artistas parecidos.
class ArtistScreen extends ConsumerStatefulWidget {
  final ArtistResult artist;

  const ArtistScreen({super.key, required this.artist});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  late final _catalog = ref.read(catalogProvider);
  late final _discovery = ref.read(discoveryProvider);

  List<AlbumResult> _albums = [];
  List<Song> _topSongs = [];
  List<DiscoveryArtist> _similar = [];
  String? _photo;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _photo = widget.artist.artworkUrl;
    _load();
  }

  Future<void> _load() async {
    final albumsFuture = _catalog.getArtistAlbums(widget.artist.artistId);
    final deezer = await _discovery.artist(widget.artist.name);
    final results = await Future.wait([
      albumsFuture,
      if (deezer?.deezerId != null) _discovery.topTracks(deezer!.deezerId!, limit: 10),
      if (deezer?.deezerId != null) _discovery.related(deezer!.deezerId!, limit: 12),
    ]);
    var top = results.length > 1 ? results[1] as List<Song> : <Song>[];
    if (top.isEmpty) top = await _catalog.getArtistSongs(widget.artist.artistId, limit: 10);
    // La misma canción del sencillo y del álbum: una sola vez.
    final seen = <String>{};
    top = top.where((s) => seen.add(DiscoveryService.songKey(s))).toList();
    if (!mounted) return;
    // Versión explícita y "limpia" del mismo disco: una sola (la primera).
    final seenAlbums = <String>{};
    final albums = (results[0] as List<AlbumResult>)
        .where((a) => seenAlbums.add(a.title.toLowerCase().trim()))
        .toList();
    setState(() {
      _albums = albums;
      _topSongs = top;
      _similar = results.length > 2 ? results[2] as List<DiscoveryArtist> : [];
      _photo = deezer?.imageUrl ?? _photo ?? (albums.isNotEmpty ? albums.first.artworkUrl : null);
      _loading = false;
    });
  }

  // Los álbumes de 6 canciones o más son "álbumes"; el resto, sencillos y EP.
  List<AlbumResult> get _fullAlbums => _albums.where((a) => (a.trackCount ?? 99) >= 6).toList();
  List<AlbumResult> get _singles => _albums.where((a) => (a.trackCount ?? 99) < 6).toList();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final heroHeight = (width * 0.8).clamp(280.0, 420.0);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: [
          _hero(heroHeight),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_topSongs.isNotEmpty) ...[
            const SizedBox(height: 22),
            SectionHeader(
              title: 'Canciones principales',
              onSeeAll: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SongListScreen(
                  title: widget.artist.name,
                  subtitle: 'Canciones principales',
                  songs: _topSongs,
                ),
              )),
            ),
            const SizedBox(height: 8),
            RankedPager(songs: _topSongs),
          ],
          if (_albums.isNotEmpty) ...[
            const SizedBox(height: 22),
            const SectionHeader(title: 'Último lanzamiento'),
            const SizedBox(height: 10),
            _LatestRelease(album: _albums.first),
          ],
          if (_fullAlbums.isNotEmpty) ...[
            const SizedBox(height: 26),
            const SectionHeader(title: 'Álbumes'),
            const SizedBox(height: 10),
            AlbumCardRow(albums: _fullAlbums, size: width > 700 ? 180 : 150),
          ],
          if (_singles.isNotEmpty) ...[
            const SizedBox(height: 22),
            const SectionHeader(title: 'Sencillos y EP'),
            const SizedBox(height: 10),
            AlbumCardRow(albums: _singles, size: width > 700 ? 160 : 130),
          ],
          if (_similar.isNotEmpty) ...[
            const SizedBox(height: 22),
            const SectionHeader(title: 'Artistas similares'),
            const SizedBox(height: 10),
            ArtistCircleRow(artists: _similar),
          ],
          if (!_loading && _albums.isEmpty && _topSongs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No se encontró música de este artista.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _hero(double height) {
    final accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_photo != null)
            CachedNetworkImage(
              imageUrl: _photo!,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.3),
              fadeInDuration: const Duration(milliseconds: 250),
              errorWidget: (_, __, ___) => Container(color: AppTheme.surface),
            )
          else
            Container(color: AppTheme.surface),
          // Se funde con el fondo abajo, para que el nombre se lea.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.45, 1],
                colors: [Colors.black26, Colors.transparent, AppTheme.background],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 90,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.artist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                    height: 1.05,
                    shadows: [Shadow(blurRadius: 18, color: Colors.black54)],
                  ),
                ),
                if (widget.artist.genre != null)
                  Text(
                    widget.artist.genre!,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
              ],
            ),
          ),
          if (_topSongs.isNotEmpty)
            Positioned(
              right: 20,
              bottom: 18,
              child: Material(
                color: accent,
                shape: const CircleBorder(),
                elevation: 6,
                child: IconButton(
                  tooltip: 'Reproducir',
                  iconSize: 34,
                  padding: const EdgeInsets.all(10),
                  icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                  onPressed: () =>
                      playSong(context, _topSongs.first, upNext: _topSongs.sublist(1)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// El último disco, grande y con su fecha.
class _LatestRelease extends StatelessWidget {
  final AlbumResult album;

  const _LatestRelease({required this.album});

  static const _months = [
    'ENE', 'FEB', 'MAR', 'ABR', 'MAY', 'JUN', //
    'JUL', 'AGO', 'SEP', 'OCT', 'NOV', 'DIC',
  ];

  @override
  Widget build(BuildContext context) {
    final date = album.releaseDate == null ? null : DateTime.tryParse(album.releaseDate!);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AlbumScreen(album: album)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            CachedArtwork(url: album.artworkUrl, size: 110, borderRadius: 10),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (date != null)
                    Text(
                      '${date.day} ${_months[date.month - 1]} ${date.year}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    album.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  if (album.trackCount != null)
                    Text(
                      album.trackCount == 1 ? '1 canción' : '${album.trackCount} canciones',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
