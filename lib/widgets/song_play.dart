import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../providers.dart';
import '../screens/lyrics_screen.dart';
import '../services/playback_service.dart';
import '../services/settings_service.dart';
import 'song_actions_sheet.dart';

/// La canción que se le acaba de pedir a la app de música (mientras se
/// busca y arranca). El mini reproductor la muestra con un indicador.
final ValueNotifier<Song?> pendingPlay = ValueNotifier(null);

/// Pone a sonar [song] (con [upNext] detrás) y avisa si algo salió mal.
/// Sirve desde cualquier pantalla: toma los servicios del [ProviderScope].
Future<void> playSong(
  BuildContext context,
  Song song, {
  List<Song> upNext = const [],
  String? service,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  HapticFeedback.selectionClick();
  var via = service ?? SettingsService.playService.value;
  if (via == 'spotify' && !await container.read(spotifyAuthProvider).isConnected()) {
    if (!context.mounted) return;
    final choice = await _askSpotifyConnect(context);
    if (choice == null || !context.mounted) return;
    if (choice == 'apple') {
      via = 'apple';
    } else if (choice == 'connect') {
      try {
        await container.read(spotifyAuthProvider).connect();
        container.read(homeFeedProvider).refresh();
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
        return;
      }
    }
  }
  service = via;
  pendingPlay.value = song;
  PlayOutcome outcome;
  try {
    outcome = await container.read(playbackProvider).play(song, upNext: upNext, service: service);
  } finally {
    if (identical(pendingPlay.value, song)) pendingPlay.value = null;
  }
  if (outcome.played) {
    // Que Reproduciendo se entere ya (sin esperar al próximo sondeo).
    Future.delayed(const Duration(milliseconds: 700), () {
      container.read(nowPlayingServiceProvider).refresh();
    });
  }
  final message = outcome.message;
  if (message != null && messenger != null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: Duration(seconds: message.length > 90 ? 10 : 4),
      ));
  }
}

/// Spotify sin conectar: ofrece conectarlo (una sola vez) para que las
/// canciones suenen directo. Devuelve 'connect', 'apple', 'search' o null.
Future<String?> _askSpotifyConnect(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Conecta Spotify'),
      content: const SizedBox(
        width: 380,
        child: Text(
          'Para que las canciones suenen directo en Spotify, Letras tiene que conectarse '
          'a tu cuenta una vez. Se abre el navegador para que aceptes.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'search'),
          child: const Text('Solo buscarla'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'apple'),
          child: const Text('Usar Apple Music'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'connect'),
          child: const Text('Conectar'),
        ),
      ],
    ),
  );
}

/// Busca la letra de [song] (guardada o en internet) y la abre.
Future<void> openLyricsFor(BuildContext context, Song song) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final saved = await container.read(storageProvider).getSaved(song.title, song.artist);
    final result = saved ??
        await container
            .read(lyricsFinderProvider)
            .find(song.title, song.artist, durationSeconds: song.durationSeconds);
    navigator.pop();
    if (result == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se encontró la letra de esta canción.')),
      );
      return;
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => LyricsScreen(result: result, originalSong: song)),
    );
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('Error buscando la letra: $e')));
  }
}

/// Las dos formas de reproducir, para las hojas de acciones: primero el
/// servicio elegido en Ajustes.
List<SongSheetAction> playSheetActions(BuildContext context, Song song,
    {List<Song> upNext = const []}) {
  final main = SettingsService.playService.value;
  final other = main == 'apple' ? 'spotify' : 'apple';
  return [
    SongSheetAction(
      icon: Icons.play_arrow_rounded,
      label: 'Reproducir en ${PlaybackService.serviceName(main)}',
      onTap: () => playSong(context, song, upNext: upNext, service: main),
    ),
    SongSheetAction(
      icon: Icons.play_circle_outline_rounded,
      label: 'Reproducir en ${PlaybackService.serviceName(other)}',
      onTap: () => playSong(context, song, upNext: upNext, service: other),
    ),
  ];
}

/// Hoja de acciones de una canción del catálogo: reproducir (en los dos
/// servicios) y ver la letra.
Future<void> showPlayableSongSheet(BuildContext context, Song song,
    {List<Song> upNext = const []}) {
  return showSongActionsSheet(
    context,
    song: song,
    onViewLyrics: () => openLyricsFor(context, song),
    leadingActions: playSheetActions(context, song, upNext: upNext),
  );
}
