import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controllers/now_playing_controller.dart';
import 'services/artwork_service.dart';
import 'services/audio_recognition_service.dart';
import 'services/favorites_sync_service.dart';
import 'services/genius_service.dart';
import 'services/history_service.dart';
import 'services/itunes_catalog_service.dart';
import 'services/lrclib_service.dart';
import 'services/lyrics_download_helper.dart';
import 'services/lyrics_finder.dart';
import 'services/lyrics_storage_service.dart';
import 'services/now_playing_service.dart';
import 'services/playlist_service.dart';
import 'services/settings_service.dart';
import 'services/spotify_auth_service.dart';
import 'services/spotify_service.dart';
import 'services/stats_service.dart';
import 'services/translation_service.dart';

// Un solo lugar donde se crean los servicios de la app. Antes cada
// pantalla hacía su propio `LrclibService()`, `LyricsStorageService()`,
// etc.; ahora todas leen la misma instancia de aquí, y en los tests se
// pueden reemplazar por versiones simuladas con `ProviderScope(overrides: ...)`.

final lrclibProvider = Provider<LrclibService>((ref) => LrclibService());
final lyricsFinderProvider =
    Provider<LyricsFinder>((ref) => LyricsFinder(lrclib: ref.watch(lrclibProvider)));
final storageProvider = Provider<LyricsStorageService>((ref) => LyricsStorageService());
final translationProvider = Provider<TranslationService>((ref) => TranslationService());
final artworkProvider = Provider<ArtworkService>((ref) => ArtworkService());
final catalogProvider = Provider<ItunesCatalogService>((ref) => ItunesCatalogService());
final historyProvider = Provider<HistoryService>((ref) => HistoryService());
final settingsProvider = Provider<SettingsService>((ref) => SettingsService());
final nowPlayingServiceProvider = Provider<NowPlayingService>((ref) => NowPlayingService());
final audioRecognitionProvider =
    Provider<AudioRecognitionService>((ref) => AudioRecognitionService());
final spotifyAuthProvider = Provider<SpotifyAuthService>((ref) => SpotifyAuthService());
final spotifyProvider = Provider<SpotifyService>((ref) => SpotifyService());
final statsProvider = Provider<StatsService>((ref) => StatsService());
final geniusProvider = Provider<GeniusService>((ref) => GeniusService());
final playlistProvider = Provider<PlaylistService>((ref) => PlaylistService());
final favoritesSyncProvider = Provider<FavoritesSyncService>((ref) => FavoritesSyncService());
final downloadHelperProvider = Provider<LyricsDownloadHelper>((ref) => LyricsDownloadHelper());

/// Todo lo de "Reproduciendo": qué suena, su letra, traducción, desfase,
/// micrófono... Vive mientras viva la app (no depende de la pantalla).
final nowPlayingControllerProvider = ChangeNotifierProvider<NowPlayingController>((ref) {
  final controller = NowPlayingController(
    nowPlaying: ref.watch(nowPlayingServiceProvider),
    finder: ref.watch(lyricsFinderProvider),
    storage: ref.watch(storageProvider),
    translation: ref.watch(translationProvider),
    artwork: ref.watch(artworkProvider),
    history: ref.watch(historyProvider),
    settings: ref.watch(settingsProvider),
    recognition: ref.watch(audioRecognitionProvider),
    stats: ref.watch(statsProvider),
  );
  controller.start();
  return controller;
});
