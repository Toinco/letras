import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../providers.dart';
import '../services/apple_music_history.dart';
import '../services/discovery_service.dart';
import '../services/stats_service.dart';
import '../theme/app_theme.dart';
import '../utils/platform.dart';
import '../widgets/apple_ui.dart';
import '../widgets/cached_artwork.dart';
import '../widgets/desktop.dart';
import '../widgets/song_play.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

/// De dónde salen las estadísticas.
enum _Source { letras, spotify, apple }

/// Tu perfil: lo que más escuchas y lo último que escuchaste, en Letras, en
/// Spotify y en Apple Music (como "Replay" de Apple Music y "Wrapped" de
/// Spotify, pero cuando quieras).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  _Source _source = isMac ? _Source.apple : _Source.letras;

  /// Período (según la fuente): 0 = último mes, 1 = medio año, 2 = siempre.
  int _period = 0;
  bool _loading = true;
  String? _error;

  // Perfil de Spotify (nombre y foto), si está conectado.
  ({String name, String? imageUrl})? _spotifyProfile;
  bool _spotifyConnected = false;
  bool _spotifyCanRead = false;

  // Lo que se muestra.
  List<({String value, String label, IconData icon})> _tiles = [];
  List<Song> _topSongs = [];
  List<String> _topSongCaptions = [];
  List<DiscoveryArtist> _topArtists = [];
  List<String> _artistCaptions = [];
  List<Song> _recent = [];

  AppleMusicHistory? _apple;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = ref.read(spotifyAuthProvider);
    _spotifyConnected = await auth.isConnected();
    _spotifyCanRead = _spotifyConnected && await auth.canReadListening();
    if (_spotifyConnected) {
      ref.read(spotifyProvider).profile().then((p) {
        if (mounted) setState(() => _spotifyProfile = p);
      });
    }
    if (!isMac && _spotifyCanRead) _source = _Source.spotify;
    await _load();
  }

  static String _plays(int n) => n == 1 ? '1 vez' : '$n veces';

  static String _hours(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h';
    return '${d.inMinutes} min';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (_source) {
        case _Source.letras:
          await _loadLetras();
        case _Source.spotify:
          await _loadSpotify();
        case _Source.apple:
          await _loadApple();
      }
    } catch (e) {
      _error = '$e'.replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _loading = false);
    _loadArtistPhotos();
  }

  Future<void> _loadLetras() async {
    final now = DateTime.now();
    final since = switch (_period) {
      0 => now.subtract(const Duration(days: 30)),
      1 => now.subtract(const Duration(days: 182)),
      _ => null,
    };
    final ListeningStats st = await ref.read(statsProvider).load(since: since, top: 25);
    _tiles = [
      (value: '${st.totalPlays}', label: 'Reproducciones', icon: Icons.play_circle_rounded),
      (value: '${st.distinctSongs}', label: 'Canciones', icon: Icons.music_note_rounded),
      (value: _hours(st.lyricsTime), label: 'Con la letra', icon: Icons.lyrics_rounded),
    ];
    _topSongs = [for (final t in st.topSongs) Song(title: t.title, artist: t.artist)];
    _topSongCaptions = [for (final t in st.topSongs) _plays(t.plays)];
    _topArtists = [for (final a in st.topArtists) DiscoveryArtist(name: a.artist)];
    _artistCaptions = [for (final a in st.topArtists) _plays(a.plays)];
    _recent = (await ref.read(historyProvider).list()).take(25).toList();
  }

  Future<void> _loadSpotify() async {
    if (!_spotifyCanRead) {
      _tiles = [];
      _topSongs = [];
      _topArtists = [];
      _recent = [];
      return;
    }
    final range = ['short_term', 'medium_term', 'long_term'][_period];
    final spotify = ref.read(spotifyProvider);
    final results = await Future.wait([
      spotify.topTracks(range: range, limit: 25),
      spotify.topArtists(range: range, limit: 20),
      spotify.recentlyPlayed(limit: 50),
    ]);
    _topSongs = results[0] as List<Song>;
    _topSongCaptions = [];
    final artists = results[1] as List<({String name, String? imageUrl})>;
    _topArtists = [for (final a in artists) DiscoveryArtist(name: a.name, imageUrl: a.imageUrl)];
    _artistCaptions = [];
    _recent = results[2] as List<Song>;
    final minutes = _topSongs.fold(0, (a, s) => a + (s.durationSeconds ?? 0)) ~/ 60;
    _tiles = [
      (value: '${_topSongs.length}', label: 'En tu top', icon: Icons.star_rounded),
      (value: '${_topArtists.length}', label: 'Artistas', icon: Icons.person_rounded),
      (value: '$minutes min', label: 'Tu top de corrido', icon: Icons.timer_rounded),
    ];
  }

  Future<void> _loadApple() async {
    final apple = _apple ??= await AppleMusicHistory.load(launch: true);
    if (apple.isEmpty) {
      _apple = null; // reintentar la próxima (quizás Música estaba cerrada)
      throw Exception('No se pudo leer tu biblioteca de Música. Abre la app Música y vuelve a intentar.');
    }
    final top = apple.topSongs(25);
    final artists = apple.topArtists(20);
    _tiles = [
      (value: '${apple.totalPlays}', label: 'Reproducciones', icon: Icons.play_circle_rounded),
      (value: '${apple.songs.length}', label: 'Canciones', icon: Icons.music_note_rounded),
      (value: _hours(apple.listeningTime), label: 'Escuchado', icon: Icons.headphones_rounded),
    ];
    _topSongs = [for (final p in top) p.song];
    _topSongCaptions = [for (final p in top) _plays(p.plays)];
    _topArtists = [for (final a in artists) DiscoveryArtist(name: a.artist)];
    _artistCaptions = [for (final a in artists) _plays(a.plays)];
    _recent = [for (final p in apple.recent(25)) p.song];
  }

  /// Fotos de los artistas que no traen (Letras y Apple Music), de Deezer.
  Future<void> _loadArtistPhotos() async {
    final source = _source;
    final discovery = ref.read(discoveryProvider);
    final withPhotos = await Future.wait(_topArtists.map((a) async {
      if (a.imageUrl != null) return a;
      final found = await discovery.artist(a.name);
      return DiscoveryArtist(name: a.name, imageUrl: found?.imageUrl);
    }));
    if (mounted && source == _source) setState(() => _topArtists = withPhotos);
  }

  void _setSource(_Source s) {
    if (s == _source) return;
    setState(() {
      _source = s;
      _period = 0;
    });
    _load();
  }

  Future<void> _connectSpotify() async {
    try {
      await ref.read(spotifyAuthProvider).connect();
      ref.read(homeFeedProvider).refresh();
      await _init();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  List<String> get _periodLabels => switch (_source) {
        _Source.spotify => ['4 semanas', '6 meses', 'Siempre'],
        _Source.letras => ['Este mes', '6 meses', 'Siempre'],
        _Source.apple => [],
      };

  @override
  Widget build(BuildContext context) {
    final name = _spotifyProfile?.name.isNotEmpty == true ? _spotifyProfile!.name : 'Tu perfil';
    return ReadableFrame(
      maxWidth: 900,
      child: Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
              tooltip: 'Ajustes',
              icon: const Icon(Icons.settings_rounded, color: AppTheme.textSecondary),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            _apple = null;
            await _load();
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 140),
            children: [
              _ProfileHeader(name: name, imageUrl: _spotifyProfile?.imageUrl),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedButton<_Source>(
                  showSelectedIcon: false,
                  segments: [
                    const ButtonSegment(value: _Source.letras, label: Text('Letras')),
                    const ButtonSegment(value: _Source.spotify, label: Text('Spotify')),
                    if (isMac)
                      const ButtonSegment(value: _Source.apple, label: Text('Apple Music')),
                  ],
                  selected: {_source},
                  onSelectionChanged: (v) => _setSource(v.first),
                ),
              ),
              if (_periodLabels.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (var i = 0; i < _periodLabels.length; i++)
                        ChoiceChip(
                          label: Text(_periodLabels[i]),
                          selected: _period == i,
                          showCheckmark: false,
                          onSelected: (_) {
                            setState(() => _period = i);
                            _load();
                          },
                        ),
                    ],
                  ),
                ),
              if (_source == _Source.apple)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Text(
                    'Según tu biblioteca de Música en esta Mac.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                ),
              ..._content(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content() {
    if (_loading) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_source == _Source.spotify && !_spotifyCanRead) {
      return [
        _Notice(
          icon: Icons.link_rounded,
          text: _spotifyConnected
              ? 'Reconecta Spotify para ver tu top y lo último que escuchaste.'
              : 'Conecta Spotify para ver tu top y lo último que escuchaste.',
          action: _spotifyConnected ? 'Reconectar' : 'Conectar',
          onAction: _connectSpotify,
        ),
      ];
    }
    if (_error != null) {
      return [_Notice(icon: Icons.info_outline_rounded, text: _error!)];
    }
    if (_topSongs.isEmpty && _recent.isEmpty) {
      return [
        const _Notice(
          icon: Icons.music_note_rounded,
          text: 'Todavía no hay nada para mostrar en este período.',
        ),
      ];
    }
    return [
      if (_tiles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
              for (var i = 0; i < _tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    value: _tiles[i].value,
                    label: _tiles[i].label,
                    icon: _tiles[i].icon,
                  ),
                ),
              ],
            ],
          ),
        ),
      if (_topSongs.isNotEmpty) ...[
        const SizedBox(height: 26),
        SectionHeader(
          title: 'Canciones más escuchadas',
          onSeeAll: () => openSongList(context, 'Tus más escuchadas', _topSongs, ranked: true),
        ),
        const SizedBox(height: 10),
        PlayShuffleButtons(songs: _topSongs),
        const SizedBox(height: 8),
        for (var i = 0; i < _topSongs.length && i < 10; i++)
          _RankedSong(
            rank: i + 1,
            song: _topSongs[i],
            caption: i < _topSongCaptions.length ? _topSongCaptions[i] : null,
            upNext: _topSongs.sublist(i + 1),
          ),
      ],
      if (_topArtists.isNotEmpty) ...[
        const SizedBox(height: 26),
        const SectionHeader(title: 'Artistas más escuchados'),
        const SizedBox(height: 10),
        ArtistCircleRow(
          artists: _topArtists,
          captions: _artistCaptions.isEmpty ? null : _artistCaptions,
        ),
      ],
      if (_recent.isNotEmpty) ...[
        const SizedBox(height: 26),
        SectionHeader(
          title: 'Escuchado recientemente',
          onSeeAll: () => openSongList(context, 'Escuchado recientemente', _recent),
        ),
        const SizedBox(height: 10),
        SongCardRow(songs: _recent, size: 140),
      ],
      if (_source == _Source.letras) ...[
        const SizedBox(height: 20),
        Center(
          child: TextButton.icon(
            icon: const Icon(Icons.bar_chart_rounded),
            label: const Text('Más detalles'),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatsScreen())),
          ),
        ),
      ],
    ];
  }
}

class _ProfileHeader extends StatelessWidget {
  final String name;
  final String? imageUrl;

  const _ProfileHeader({required this.name, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Column(
      children: [
        if (imageUrl != null)
          CachedArtwork(url: imageUrl, size: 96, borderRadius: 48, fallbackIcon: Icons.person)
        else
          Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent,
                  HSLColor.fromColor(accent)
                      .withHue((HSLColor.fromColor(accent).hue + 50) % 360)
                      .toColor()
                ],
              ),
            ),
            child: Text(
              initial,
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          name,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.4),
        ),
        const SizedBox(height: 2),
        const Text(
          'Lo que escuchas, en todos lados',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      ],
    );
  }
}

class _RankedSong extends StatelessWidget {
  final int rank;
  final Song song;
  final String? caption;
  final List<Song> upNext;

  const _RankedSong({
    required this.rank,
    required this.song,
    this.caption,
    required this.upNext,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => playSong(context, song, upNext: upNext),
      onLongPress: () => showPlayableSongSheet(context, song, upNext: upNext),
      onSecondaryTap: () => showPlayableSongSheet(context, song, upNext: upNext),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: rank <= 3 ? Theme.of(context).colorScheme.primary : AppTheme.textSecondary,
                ),
              ),
            ),
            SongThumb(song: song, size: 50),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            if (caption != null)
              Text(caption!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  const _Notice({required this.icon, required this.text, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 50, 32, 0),
      child: Column(
        children: [
          Icon(icon, size: 40, color: AppTheme.textSecondary),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary)),
          if (action != null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    );
  }
}
