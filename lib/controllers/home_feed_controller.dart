import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/album_result.dart';
import '../models/song.dart';
import '../services/apple_music_history.dart';
import '../services/discovery_service.dart';
import '../services/error_log.dart';
import '../services/history_service.dart';
import '../services/spotify_auth_service.dart';
import '../services/spotify_service.dart';
import '../services/stats_service.dart';

/// Una sección "Porque escuchas X".
typedef ForYouSection = ({String seed, List<Song> songs});

/// Todo lo que muestra la pestaña Inicio.
///
/// Lo tuyo (recientes, más escuchadas, tus artistas) sale de lo que Letras
/// registra mientras escuchas. Las recomendaciones y los rankings vienen de
/// internet y se guardan unas horas, así Inicio aparece completo al instante
/// cada vez que abres la app.
class HomeFeedController extends ChangeNotifier {
  final HistoryService history;
  final StatsService stats;
  final DiscoveryService discovery;
  final SpotifyService spotify;
  final SpotifyAuthService spotifyAuth;

  HomeFeedController({
    required this.history,
    required this.stats,
    required this.discovery,
    required this.spotify,
    required this.spotifyAuth,
  });

  static const _cacheKey = 'home_feed_cache_v1';
  static const _maxAge = Duration(hours: 6);

  // --- Lo tuyo ---
  List<Song> recent = [];
  List<Song> topSongs = [];
  List<DiscoveryArtist> topArtists = [];

  // --- De internet ---
  List<ForYouSection> forYou = [];
  List<Song> mix = [];
  List<DiscoveryArtist> suggestedArtists = [];
  List<Song> countryChart = [];
  List<Song> globalChart = [];
  List<AlbumResult> topAlbums = [];
  List<Song> spotifyRecent = [];
  List<Song> spotifyTop = [];

  // --- Tu Apple Music (biblioteca de Música en la Mac) ---
  List<Song> appleTop = [];
  List<Song> appleRecent = [];
  List<String> _appleArtists = [];

  bool loadingOnline = false;
  DateTime? _onlineAt;
  bool _started = false;
  bool _disposed = false;

  bool get isEmpty =>
      recent.isEmpty &&
      topSongs.isEmpty &&
      appleTop.isEmpty &&
      countryChart.isEmpty &&
      globalChart.isEmpty;

  void start() {
    if (_started) return;
    _started = true;
    HistoryService.changes.addListener(_onHistoryChanged);
    unawaited(_init());
  }

  Future<void> _init() async {
    await _readCache();
    await _loadLocal();
    await refreshOnline();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Timer? _historyDebounce;

  void _onHistoryChanged() {
    _historyDebounce?.cancel();
    _historyDebounce = Timer(const Duration(seconds: 2), _loadLocal);
  }

  /// Vuelve a cargar todo (al tirar hacia abajo en Inicio).
  Future<void> refresh() async {
    await _loadLocal();
    await refreshOnline(force: true);
  }

  // ---------------------------------------------------------------- lo tuyo

  Future<void> _loadLocal() async {
    try {
      final apple = await AppleMusicHistory.load();
      if (!apple.isEmpty) {
        appleTop = [for (final p in apple.topSongs(20)) p.song];
        appleRecent = [for (final p in apple.recent(20)) p.song];
        _appleArtists = [for (final a in apple.topArtists(5)) a.artist];
      }
      recent = (await history.list()).take(20).toList();
      final now = DateTime.now();
      var month = await stats.load(since: now.subtract(const Duration(days: 30)), top: 20);
      if (month.topSongs.length < 4) month = await stats.load(top: 20);
      topSongs = [for (final t in month.topSongs) Song(title: t.title, artist: t.artist)];

      var artistStats = await stats.load(since: now.subtract(const Duration(days: 90)), top: 12);
      if (artistStats.topArtists.length < 3) artistStats = await stats.load(top: 12);
      final names = artistStats.topArtists.map((a) => a.artist).where((n) => n.trim().isNotEmpty);
      // Primero sin foto (al instante), después con la foto de Deezer.
      topArtists = [
        for (final n in names)
          topArtists.where((a) => a.name == n).firstOrNull ?? DiscoveryArtist(name: n),
      ];
      _notify();
      final withPhotos = await Future.wait(names.map((n) async {
        final found = await discovery.artist(n);
        return DiscoveryArtist(name: n, imageUrl: found?.imageUrl, deezerId: found?.deezerId);
      }));
      topArtists = withPhotos;
      _notify();
    } catch (e, st) {
      ErrorLog.record('home', e, st);
    }
  }

  // ------------------------------------------------------------- de internet

  /// Artistas de los que salen las recomendaciones: los que más escuchas en
  /// Letras y, si no alcanzan, los de tu Spotify y tus recientes.
  List<String> _seeds() {
    final seeds = <String>[];
    void add(String artist) {
      final a = artist.split(RegExp(r',| & | feat\.? | ft\.? ', caseSensitive: false)).first.trim();
      if (a.isEmpty) return;
      if (seeds.any((s) => s.toLowerCase() == a.toLowerCase())) return;
      seeds.add(a);
    }

    for (final a in topArtists) {
      add(a.name);
    }
    for (final a in _appleArtists) {
      add(a);
    }
    for (final s in [...spotifyTop, ...spotifyRecent, ...recent]) {
      add(s.artist);
    }
    return seeds.take(5).toList();
  }

  Future<void> refreshOnline({bool force = false}) async {
    if (loadingOnline) return;
    final fresh = _onlineAt != null && DateTime.now().difference(_onlineAt!) < _maxAge;
    if (fresh && !force) return;
    loadingOnline = true;
    _notify();
    try {
      await Future.wait([
        _loadSpotify(),
        discovery.countryChart().then((v) {
          if (v.isNotEmpty) countryChart = v;
        }),
        discovery.globalChart().then((v) {
          if (v.isNotEmpty) globalChart = v;
        }),
        discovery.countryTopAlbums().then((v) {
          if (v.isNotEmpty) topAlbums = v;
        }),
      ]);
      _notify();

      final known = <String>{
        for (final s in [
          ...recent,
          ...topSongs,
          ...spotifyRecent,
          ...spotifyTop,
          ...appleTop,
          ...appleRecent,
        ])
          DiscoveryService.songKey(s),
        for (final r in await stats.exportRows())
          DiscoveryService.songKey(
              Song(title: r['title'] as String? ?? '', artist: r['artist'] as String? ?? '')),
      };
      final seeds = _seeds();
      if (seeds.isNotEmpty) {
        final rec = await discovery.recommendations(seeds, known);
        if (rec.sections.isNotEmpty) {
          forYou = rec.sections;
          suggestedArtists = rec.artists;
          mix = _interleave(rec.sections.map((s) => s.songs).toList()).take(30).toList();
        }
      }
      _onlineAt = DateTime.now();
      await _writeCache();
    } catch (e, st) {
      ErrorLog.record('home', e, st);
    } finally {
      loadingOnline = false;
      _notify();
    }
  }

  Future<void> _loadSpotify() async {
    try {
      if (!await spotifyAuth.isConnected() || !await spotifyAuth.canReadListening()) return;
      final results = await Future.wait([spotify.recentlyPlayed(), spotify.topTracks()]);
      spotifyRecent = results[0];
      spotifyTop = results[1];
    } catch (_) {
      // Sin Spotify (o sin permiso): Inicio sigue sin esas secciones.
    }
  }

  static List<Song> _interleave(List<List<Song>> lists) {
    final out = <Song>[];
    for (var i = 0; lists.any((l) => i < l.length); i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ caché

  Future<void> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      List<Song> songs(String k) => [
            for (final s in (j[k] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
              Song.fromJson(s),
          ];
      _onlineAt = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0);
      countryChart = songs('countryChart');
      globalChart = songs('globalChart');
      mix = songs('mix');
      spotifyRecent = songs('spotifyRecent');
      spotifyTop = songs('spotifyTop');
      topAlbums = [
        for (final a in (j['topAlbums'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
          AlbumResult(
            collectionId: (a['id'] as num).toInt(),
            title: a['title'] as String? ?? '',
            artist: a['artist'] as String? ?? '',
            artworkUrl: a['art'] as String?,
            releaseDate: a['date'] as String?,
          ),
      ];
      forYou = [
        for (final s in (j['forYou'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
          (
            seed: s['seed'] as String? ?? '',
            songs: [
              for (final x
                  in (s['songs'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
                Song.fromJson(x),
            ],
          ),
      ];
      suggestedArtists = [
        for (final a in (j['suggested'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>())
          DiscoveryArtist.fromJson(a),
      ];
      _notify();
    } catch (_) {
      // Caché vieja o rota: se vuelve a armar.
    }
  }

  Future<void> _writeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<Map<String, dynamic>> songs(List<Song> l) => [for (final s in l) s.toJson()];
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'at': _onlineAt?.millisecondsSinceEpoch,
          'countryChart': songs(countryChart),
          'globalChart': songs(globalChart),
          'mix': songs(mix),
          'spotifyRecent': songs(spotifyRecent),
          'spotifyTop': songs(spotifyTop),
          'topAlbums': [
            for (final a in topAlbums)
              {
                'id': a.collectionId,
                'title': a.title,
                'artist': a.artist,
                'art': a.artworkUrl,
                'date': a.releaseDate,
              },
          ],
          'forYou': [
            for (final s in forYou) {'seed': s.seed, 'songs': songs(s.songs)},
          ],
          'suggested': [for (final a in suggestedArtists) a.toJson()],
        }),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _historyDebounce?.cancel();
    HistoryService.changes.removeListener(_onHistoryChanged);
    super.dispose();
  }
}
