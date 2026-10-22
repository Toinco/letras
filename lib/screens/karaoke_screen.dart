import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/lyrics_result.dart';
import '../widgets/synced_lyrics_view.dart';
import '../utils/platform.dart';
import '../widgets/desktop.dart';

/// Modo karaoke para la tele: solo la línea actual, enorme y centrada,
/// con la siguiente chiquita abajo. Pantalla completa y siempre encendida.
/// Pensado para duplicar la pantalla del celular en un televisor.
class KaraokeScreen extends StatefulWidget {
  final LyricsResult lyrics;
  final Stream<Duration> position;
  final Duration offset;
  final List<String>? translatedLines;
  final bool showTranslation;
  final Uint8List? artworkBytes;

  /// Si vienen, el karaoke no se queda con la foto del momento en que se
  /// abrió: cada vez que [updates] avisa, vuelve a leer [liveContent] (así
  /// aparece la traducción que llega después, o la letra de la canción
  /// siguiente).
  final Listenable? updates;
  final KaraokeContent Function()? liveContent;

  const KaraokeScreen({
    super.key,
    required this.lyrics,
    required this.position,
    this.offset = Duration.zero,
    this.translatedLines,
    this.showTranslation = false,
    this.artworkBytes,
    this.updates,
    this.liveContent,
  });

  @override
  State<KaraokeScreen> createState() => _KaraokeScreenState();
}

class _KaraokeScreenState extends State<KaraokeScreen> {
  bool _showClose = true;

  /// En la Mac el karaoke pone la ventana en pantalla completa (y la deja
  /// como estaba al salir).
  bool _enteredFullScreen = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable().catchError((_) {});
    if (isDesktop && !DesktopWindow.fullScreen.value) {
      _enteredFullScreen = true;
      DesktopWindow.toggleFullScreen();
    }
    _hideCloseSoon();
  }

  void _hideCloseSoon() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showClose = false);
    });
  }

  @override
  void dispose() {
    // Si volvemos a Reproduciendo en horizontal, sigue en pantalla completa.
    final size = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    if (size.height >= size.width) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    WakelockPlus.disable().catchError((_) {});
    if (_enteredFullScreen && DesktopWindow.fullScreen.value) DesktopWindow.toggleFullScreen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // Un toque en cualquier lado muestra el botón de cerrar un ratito.
        onTap: () {
          setState(() => _showClose = true);
          _hideCloseSoon();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
                    Colors.black,
                  ],
                  radius: 1.1,
                ),
              ),
            ),
            SafeArea(
              child: ListenableBuilder(
                listenable: widget.updates ?? const _NoUpdates(),
                builder: (context, _) {
                  final content = widget.liveContent?.call() ??
                      KaraokeContent(
                        lyrics: widget.lyrics,
                        translatedLines: widget.translatedLines,
                        showTranslation: widget.showTranslation,
                        offset: widget.offset,
                      );
                  return SyncedLyricsView(
                    lines: content.lyrics.syncedLyrics,
                    position: widget.position,
                    plainLyricsFallback: content.lyrics.plainLyrics,
                    offset: content.offset,
                    translatedLines: content.translatedLines,
                    showTranslation: content.showTranslation,
                    song: content.lyrics.song,
                    artworkBytes: widget.artworkBytes,
                    focusMode: true,
                    showSearchButton: false,
                  );
                },
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _showClose ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !_showClose,
                    child: IconButton.filledTonal(
                      tooltip: 'Salir del modo karaoke',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lo que muestra el karaoke en un momento dado.
class KaraokeContent {
  final LyricsResult lyrics;
  final List<String>? translatedLines;
  final bool showTranslation;
  final Duration offset;

  const KaraokeContent({
    required this.lyrics,
    this.translatedLines,
    this.showTranslation = false,
    this.offset = Duration.zero,
  });
}

class _NoUpdates implements Listenable {
  const _NoUpdates();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
