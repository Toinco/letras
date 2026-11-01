import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/home_feed_controller.dart';
import '../models/song.dart';
import '../providers.dart';
import '../services/discovery_service.dart';
import '../theme/app_theme.dart';
import '../widgets/apple_ui.dart';
import '../widgets/artwork_thumb.dart';
import '../widgets/song_play.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'song_list_screen.dart';

/// Pestaña Inicio: lo mejor de Apple Music ("Escuchar ahora") y de
/// Spotify (accesos rápidos, "Porque escuchas...") juntos.
///
/// Tocar una canción la pone a sonar en el servicio elegido en Ajustes;
/// mantenerla apretada muestra más opciones (el otro servicio, la letra).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(homeFeedProvider);
    final wide = MediaQuery.sizeOf(context).width > 700;
    final card = wide ? 180.0 : 150.0;

    final sections = <Widget>[
      _Header(onSettings: _openSettings),
      if (_quickPicks(feed).length >= 4) _QuickGrid(songs: _quickPicks(feed), wide: wide),
      if (feed.mix.isNotEmpty || feed.topSongs.isNotEmpty || feed.countryChart.isNotEmpty)
        _section(
          'Para ti',
          child: _MixRow(feed: feed, wide: wide),
        ),
      if (feed.recent.isNotEmpty)
        _section(
          'Escuchado recientemente',
          onSeeAll: () => _openList('Escuchado recientemente', feed.recent),
          child: SongCardRow(songs: feed.recent, size: card),
        ),
      if (feed.topSongs.isNotEmpty)
        _section(
          'Tus más escuchadas',
          subtitle: 'Este mes en Letras',
          onSeeAll: () => _openList('Tus más escuchadas', feed.topSongs, ranked: true),
          child: RankedPager(songs: feed.topSongs),
        ),
      if (feed.topArtists.isNotEmpty)
        _section('Tus artistas', child: ArtistCircleRow(artists: feed.topArtists)),
      for (final s in feed.forYou.take(3))
        _section(
          'Porque escuchas ${s.seed}',
          onSeeAll: () => _openList('Porque escuchas ${s.seed}', s.songs),
          child: SongCardRow(songs: s.songs, size: card),
        ),
      if (feed.spotifyRecent.isNotEmpty)
        _section(
          'Volver a escuchar',
          subtitle: 'De tu Spotify',
          onSeeAll: () => _openList('Volver a escuchar', feed.spotifyRecent),
          child: SongCardRow(songs: feed.spotifyRecent, size: card),
        ),
      if (feed.suggestedArtists.isNotEmpty)
        _section('Artistas que te pueden gustar',
            child: ArtistCircleRow(artists: feed.suggestedArtists)),
      if (feed.countryChart.isNotEmpty)
        _section(
          'Top canciones de tu país',
          subtitle: 'Lo más escuchado en Apple Music',
          onSeeAll: () => _openList('Top canciones de tu país', feed.countryChart, ranked: true),
          child: RankedPager(songs: feed.countryChart, ranked: true),
        ),
      if (feed.spotifyTop.isNotEmpty)
        _section(
          'Tu top de Spotify',
          subtitle: 'Últimas semanas',
          onSeeAll: () => _openList('Tu top de Spotify', feed.spotifyTop, ranked: true),
          child: RankedPager(songs: feed.spotifyTop, ranked: true),
        ),
      if (feed.appleTop.isNotEmpty)
        _section(
          'Tu top de Apple Music',
          subtitle: 'Lo que más suena en tu biblioteca',
          onSeeAll: () => _openList('Tu top de Apple Music', feed.appleTop, ranked: true),
          child: RankedPager(songs: feed.appleTop, ranked: true),
        ),
      if (feed.appleRecent.isNotEmpty)
        _section(
          'Recién escuchado en Apple Music',
          onSeeAll: () => _openList('Recién escuchado en Apple Music', feed.appleRecent),
          child: SongCardRow(songs: feed.appleRecent, size: card),
        ),
      if (feed.topAlbums.isNotEmpty)
        _section('Álbumes del momento', child: AlbumCardRow(albums: feed.topAlbums, size: card)),
      if (feed.globalChart.isNotEmpty)
        _section(
          'Top mundial',
          onSeeAll: () => _openList('Top mundial', feed.globalChart, ranked: true),
          child: RankedPager(songs: feed.globalChart, ranked: true),
        ),
      if (feed.isEmpty) _empty(feed),
      const SizedBox(height: 190),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: feed.refresh,
          child: ListView(
            padding: EdgeInsets.zero,
            children: sections,
          ),
        ),
      ),
    );
  }

  Widget _empty(HomeFeedController feed) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 0),
      child: Column(
        children: [
          if (feed.loadingOnline)
            const CircularProgressIndicator()
          else ...[
            const Icon(Icons.wifi_off_rounded, size: 40, color: AppTheme.textSecondary),
            const SizedBox(height: 12),
            const Text(
              'Escucha algo y aquí aparecerán tus recientes, tus más escuchadas y '
              'recomendaciones para ti.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  /// Accesos rápidos (como el inicio de Spotify): lo último que escuchaste,
  /// completado con tus más escuchadas.
  List<Song> _quickPicks(HomeFeedController feed) {
    final seen = <String>{};
    final out = <Song>[];
    for (final s in [
      ...feed.recent,
      ...feed.appleRecent,
      ...feed.topSongs,
      ...feed.spotifyRecent,
    ]) {
      if (seen.add(DiscoveryService.songKey(s))) out.add(s);
      if (out.length == 8) break;
    }
    return out.length >= 6 ? out.take(out.length >= 8 ? 8 : 6).toList() : out;
  }

  void _openSettings() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));

  void _openList(String title, List<Song> songs, {bool ranked = false}) =>
      openSongList(context, title, songs, ranked: ranked);

  Widget _section(String title, {String? subtitle, VoidCallback? onSeeAll, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title: title, subtitle: subtitle, onSeeAll: onSeeAll),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ piezas

class _Header extends StatelessWidget {
  final VoidCallback onSettings;

  const _Header({required this.onSettings});

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h >= 6 && h < 13) return 'Buenos días';
    if (h >= 13 && h < 20) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting().toUpperCase(),
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const Text(
                  'Inicio',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Tu perfil y estadísticas',
            icon: const Icon(Icons.account_circle_rounded, size: 30),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings_rounded, color: AppTheme.textSecondary),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

/// Cuadrícula de accesos rápidos de dos columnas (estilo Spotify).
class _QuickGrid extends StatelessWidget {
  final List<Song> songs;
  final bool wide;

  const _QuickGrid({required this.songs, required this.wide});

  @override
  Widget build(BuildContext context) {
    final columns = wide ? 4 : 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: GridView.count(
        crossAxisCount: columns,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: wide ? 4.2 : 3.0,
        children: [
          for (var i = 0; i < songs.length; i++)
            Material(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => playSong(context, songs[i], upNext: songs.sublist(i + 1)),
                onLongPress: () => showPlayableSongSheet(context, songs[i]),
                onSecondaryTap: () => showPlayableSongSheet(context, songs[i]),
                child: LayoutBuilder(
                  builder: (context, c) => Row(
                    children: [
                      ArtworkThumb(
                        title: songs[i].title,
                        artist: songs[i].artist,
                        imageUrl: songs[i].artworkUrl,
                        size: c.maxHeight,
                        borderRadius: 0,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          songs[i].title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Las tapas grandes de "Para ti": tu mix de descubrimientos, tus más
/// escuchadas y el ranking de tu país, como las playlists de Apple Music.
class _MixRow extends StatelessWidget {
  final HomeFeedController feed;
  final bool wide;

  const _MixRow({required this.feed, required this.wide});

  @override
  Widget build(BuildContext context) {
    final size = wide ? 230.0 : 200.0;
    final cards = <Widget>[
      if (feed.mix.isNotEmpty)
        _MixCard(
          title: 'Descubrimientos',
          caption: 'Mix para ti',
          colors: const [Color(0xFFFC3C44), Color(0xFF8E2DE2)],
          songs: feed.mix,
          size: size,
        ),
      if (feed.topSongs.length >= 4)
        _MixCard(
          title: 'Tus favoritas',
          caption: 'Lo que más escuchas',
          colors: const [Color(0xFFFF9500), Color(0xFFFF2D55)],
          songs: feed.topSongs,
          size: size,
        ),
      if (feed.spotifyTop.length >= 4)
        _MixCard(
          title: 'Tu Spotify',
          caption: 'Tu top reciente',
          colors: const [Color(0xFF1DB954), Color(0xFF0B6E4F)],
          songs: feed.spotifyTop,
          size: size,
        ),
      if (feed.countryChart.length >= 4)
        _MixCard(
          title: 'Top del país',
          caption: 'Lo más escuchado',
          colors: const [Color(0xFF0A84FF), Color(0xFF5E5CE6)],
          songs: feed.countryChart,
          size: size,
        ),
    ];
    return SizedBox(
      height: size + 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) => cards[i],
      ),
    );
  }
}

class _MixCard extends StatelessWidget {
  final String title;
  final String caption;
  final List<Color> colors;
  final List<Song> songs;
  final double size;

  const _MixCard({
    required this.title,
    required this.caption,
    required this.colors,
    required this.songs,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SongListScreen(title: title, subtitle: caption, songs: songs),
      )),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
              ),
              child: Stack(
                children: [
                  // Carátulas inclinadas detrás del título.
                  Positioned(
                    right: -18,
                    bottom: -14,
                    child: Transform.rotate(
                      angle: -0.18,
                      child: Opacity(
                        opacity: 0.9,
                        child: SongCollage(songs: songs.take(4).toList(), size: size * 0.62),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    top: 14,
                    right: 14,
                    // En una sola línea, achicándose si no entra (antes
                    // "Descubrimientos" se partía a la mitad).
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                          letterSpacing: -0.4,
                          shadows: [Shadow(blurRadius: 12, color: Colors.black26)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Reproducir',
                        icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                        onPressed: () => playSong(context, songs.first, upNext: songs.sublist(1)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(
              '${songs.length} canciones',
              style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
