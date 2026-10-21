import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/lyrics_result.dart';
import '../widgets/synced_lyrics_view.dart';

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

  const KaraokeScreen({
    super.key,
    required this.lyrics,
    required this.position,
    this.offset = Duration.zero,
    this.translatedLines,
    this.showTranslation = false,
    this.artworkBytes,
  });

  @override
  State<KaraokeScreen> createState() => _KaraokeScreenState();
}

class _KaraokeScreenState extends State<KaraokeScreen> {
  bool _showClose = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable().catchError((_) {});
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
              child: SyncedLyricsView(
                lines: widget.lyrics.syncedLyrics,
                position: widget.position,
                plainLyricsFallback: widget.lyrics.plainLyrics,
                offset: widget.offset,
                translatedLines: widget.translatedLines,
                showTranslation: widget.showTranslation,
                song: widget.lyrics.song,
                artworkBytes: widget.artworkBytes,
                focusMode: true,
                showSearchButton: false,
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
