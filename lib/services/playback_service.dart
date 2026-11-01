import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/song.dart';
import '../utils/platform.dart';
import '../utils/text_normalize.dart';
import 'error_log.dart';
import 'itunes_catalog_service.dart';
import 'settings_service.dart';
import 'spotify_auth_service.dart';
import 'spotify_service.dart';

/// Cómo terminó un pedido de reproducción.
class PlayOutcome {
  /// La canción quedó sonando (o se le pidió a la app de música que la ponga).
  final bool played;

  /// Algo para avisar (por qué no sonó, o qué hacer para que suene directo).
  final String? message;

  const PlayOutcome(this.played, [this.message]);
}

/// Pone a sonar canciones elegidas en Letras, en Spotify o en Apple Music.
///
/// Letras no reproduce audio: le pide a la app de música (que tiene las
/// licencias y tu cuenta) que ponga la canción, y después la sigue como a
/// cualquier otra, con su letra.
///
/// - Spotify, con la cuenta conectada: la API de Spotify elige la canción
///   exacta y la pone en este dispositivo (con el resto de la lista detrás).
///   Sin cuenta, se le pide a la app de Spotify que la busque.
/// - Apple Music: en la Mac, si la canción está en tu biblioteca suena
///   directo; si no, se abre en Música. En Android se le pide a Apple Music
///   que la busque y la ponga.
class PlaybackService {
  static const _channel = MethodChannel('io.letras.app/now_playing');

  final SpotifyService spotify;
  final SpotifyAuthService auth;
  final ItunesCatalogService catalog;

  PlaybackService({required this.spotify, required this.auth, required this.catalog});

  /// Avisa cuando se le pidió a una app de música que ponga algo (para que
  /// la pantalla de Reproduciendo se actualice enseguida).
  static final ValueNotifier<int> requests = ValueNotifier(0);

  static String serviceName(String service) => service == 'apple' ? 'Apple Music' : 'Spotify';

  /// Pone a sonar [song]. [upNext] son las que siguen (el resto del álbum o
  /// de la lista), para que "siguiente" pase a la próxima.
  Future<PlayOutcome> play(Song song, {List<Song> upNext = const [], String? service}) async {
    final via = service ?? SettingsService.playService.value;
    try {
      final outcome = via == 'apple' ? await _playApple(song) : await _playSpotify(song, upNext);
      if (outcome.played) requests.value++;
      return outcome;
    } on SpotifyPlaybackException catch (e) {
      return PlayOutcome(false, e.message);
    } catch (e, st) {
      ErrorLog.record('playback', e, st);
      return PlayOutcome(false, 'No se pudo reproducir en ${serviceName(via)}.');
    }
  }

  // ---------------------------------------------------------------- Spotify

  Future<PlayOutcome> _playSpotify(Song song, List<Song> upNext) async {
    if (!await auth.isConnected()) {
      // Sin cuenta conectada no hay forma de saber el id exacto: se le pide
      // a la app de Spotify que la busque.
      if (isAndroid && await _invoke('playFromSearch', _searchArgs('spotify', song)) == true) {
        return const PlayOutcome(true);
      }
      await _open('spotify:search:${Uri.encodeComponent('${song.title} ${song.artist}')}',
          app: 'spotify');
      return const PlayOutcome(
        false,
        'Se abrió la búsqueda en Spotify. Conecta tu cuenta en Ajustes para que suene directo.',
      );
    }

    final found = await spotify.findTrack(song);
    if (found == null || found.spotifyUri == null) {
      return PlayOutcome(false, 'No encontré "${song.title}" en Spotify.');
    }
    final uri = found.spotifyUri!;

    if (await auth.canControlPlayback()) {
      try {
        if (await _playOnDevice(uri, upNext)) return const PlayOutcome(true);
      } on SpotifyPlaybackException {
        // Sin dispositivo o sin respuesta: en la Mac y en Android queda el
        // camino directo a la app de Spotify (abajo). En otros lados, avisar.
        if (!isMac && !isAndroid) rethrow;
      }
      // Spotify aceptó el pedido pero la app no lo puso (le pasa a la app de
      // la Mac a veces, por ejemplo recién iniciada la sesión): se lo
      // pedimos directo a la app.
      if (isMac && await _invoke('spotifyPlayUri', {'uri': uri}) == true) {
        return const PlayOutcome(true);
      }
      if (isAndroid && await _invoke('playFromSearch', _searchArgs('spotify', found)) == true) {
        return const PlayOutcome(true);
      }
      return const PlayOutcome(false, 'Spotify no respondió. Ábrelo y vuelve a intentar.');
    }

    // Conectado, pero sin el permiso de reproducción (cuenta conectada antes
    // de esta versión).
    const reconnect = 'Reconecta Spotify en Ajustes para elegir qué suena desde Letras.';
    if (isMac && await _invoke('spotifyPlayUri', {'uri': uri}) == true) {
      return const PlayOutcome(true);
    }
    if (isAndroid && await _invoke('playFromSearch', _searchArgs('spotify', found)) == true) {
      return const PlayOutcome(true, reconnect);
    }
    await _open(uri, app: 'spotify');
    return const PlayOutcome(false, reconnect);
  }

  /// Pone [uri] (y las que siguen) en el Spotify de este dispositivo. Si
  /// Spotify está cerrado, lo abre y espera a que aparezca. Devuelve si de
  /// verdad empezó a sonar (Spotify a veces acepta el pedido y no hace nada).
  Future<bool> _playOnDevice(String uri, List<Song> upNext) async {
    var device = _pickDevice(await spotify.devices());
    if (device == null) {
      if (await _invoke('launchApp', {'app': 'spotify'}) != true && !isDesktop) {
        throw const SpotifyPlaybackException('No se pudo abrir Spotify en este dispositivo.');
      }
      for (var i = 0; i < 15 && device == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        device = _pickDevice(await spotify.devices());
      }
    }
    if (device == null) {
      throw const SpotifyPlaybackException(
        'Spotify no aparece en este dispositivo. Ábrelo una vez y vuelve a intentar.',
      );
    }

    final rest = await _resolveUpNext(upNext);
    await spotify.playUris([uri, ...rest], deviceId: device.id);
    // En Android abrir Spotify lo trae al frente: volvemos a Letras.
    if (isAndroid) unawaited(_invoke('bringToFront'));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (await spotify.isPlaying(uri)) return true;
    }
    return false;
  }

  /// Las siguientes en Spotify, buscadas en paralelo y sin hacer esperar
  /// mucho: las que no aparecen a tiempo quedan afuera.
  Future<List<String>> _resolveUpNext(List<Song> upNext) async {
    if (upNext.isEmpty) return [];
    final wanted = upNext.take(30).toList();
    final results = await Future.wait([
      for (final s in wanted)
        spotify
            .findTrack(s)
            .then((f) => f?.spotifyUri)
            .timeout(const Duration(seconds: 4), onTimeout: () => null)
            .catchError((Object _) => null),
    ]);
    return results.whereType<String>().toList();
  }

  /// El dispositivo donde poner la canción: el de este aparato (la compu
  /// en la Mac/Windows, el teléfono en Android), mejor si ya está activo.
  static SpotifyDevice? _pickDevice(List<SpotifyDevice> devices) {
    final type = isDesktop ? 'computer' : 'smartphone';
    final mine = devices.where((d) => d.type.toLowerCase() == type).toList();
    return mine.where((d) => d.isActive).firstOrNull ?? mine.firstOrNull;
  }

  // ------------------------------------------------------------ Apple Music

  Future<PlayOutcome> _playApple(Song song) async {
    if (isMac) {
      final id = await _findInMusicLibrary(song);
      if (id != null && await _invoke('musicPlayPersistentId', {'id': id}) == true) {
        return const PlayOutcome(true);
      }
    }
    if (isAndroid && await _invoke('playFromSearch', _searchArgs('apple', song)) == true) {
      return const PlayOutcome(true);
    }

    // No está en la biblioteca: se abre en el catálogo de Apple Music.
    final appleId = song.appleId ?? await _findAppleId(song);
    final cc = ItunesCatalogService.storefront;
    final url = appleId != null
        ? 'https://music.apple.com/$cc/song/$appleId'
        : 'https://music.apple.com/$cc/search?term=${Uri.encodeQueryComponent('${song.title} ${song.artist}')}';
    await _open(isMac ? url.replaceFirst('https://', 'music://') : url, app: 'apple');
    return PlayOutcome(
      false,
      isMac
          ? 'No está en tu biblioteca: se abrió en Música, toca reproducir ahí.'
          : 'Se abrió en Apple Music.',
    );
  }

  /// Id (persistent ID) de la canción en la biblioteca de Música de la Mac.
  Future<String?> _findInMusicLibrary(Song song) async {
    final raw = await _invoke('musicSearchLibrary', {
      'query': cleanTitleForMatching(song.title),
    });
    if (raw is! List) return null;
    final byId = <Song, String>{};
    for (final item in raw.whereType<List<dynamic>>()) {
      if (item.length < 4) continue;
      final candidate = Song(
        title: item[1] as String? ?? '',
        artist: item[2] as String? ?? '',
        durationSeconds: (item[3] as num?)?.round(),
      );
      byId[candidate] = item[0] as String? ?? '';
    }
    final best = SpotifyService.bestMatch(song, byId.keys.toList());
    final id = best == null ? null : byId[best];
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<int?> _findAppleId(Song song) async {
    final results = await catalog.searchSongs('${song.title} ${primaryArtistName(song.artist)}');
    return SpotifyService.bestMatch(song, results)?.appleId;
  }

  // ---------------------------------------------------------------- nativo

  Map<String, Object?> _searchArgs(String app, Song song) => {
        'app': app,
        'title': cleanTitleForMatching(song.title),
        'artist': primaryArtistName(song.artist),
        'album': song.album,
      };

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e, st) {
      ErrorLog.record('playback', e, st);
      return null;
    }
  }

  /// Abre [url] en la app de música (o, sin la app, en la web).
  Future<void> _open(String url, {required String app}) async {
    if (await _invoke('openUrl', {'url': url, 'app': app}) == true) return;
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    try {
      await launchUrl(Uri.parse(_webUrl(url)), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// La versión web de un enlace de app (spotify:..., music://...).
  static String _webUrl(String url) {
    if (url.startsWith('music://')) return url.replaceFirst('music://', 'https://');
    if (url.startsWith('spotify:search:')) {
      return 'https://open.spotify.com/search/${url.substring('spotify:search:'.length)}';
    }
    if (url.startsWith('spotify:track:')) {
      return 'https://open.spotify.com/track/${url.substring('spotify:track:'.length)}';
    }
    return url;
  }
}
