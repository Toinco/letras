import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../controllers/now_playing_controller.dart';
import '../models/lyrics_result.dart';
import '../providers.dart';
import '../services/now_playing_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../utils/platform.dart';
import '../widgets/artwork_thumb.dart';
import '../widgets/desktop.dart';
import '../widgets/lyrics_picker_sheet.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/synced_lyrics_view.dart';
import 'home_shell.dart';
import 'karaoke_screen.dart';
import 'lyrics_editor_screen.dart';
import 'lyrics_screen.dart';

/// Pantalla principal: muestra lo que suena en el teléfono (Spotify,
/// YouTube Music, etc.) con su letra sincronizada en tiempo real.
///
/// Toda la lógica (qué suena, buscar la letra, traducir, desfases,
/// micrófono...) vive en [NowPlayingController]; esta pantalla solo la
/// dibuja y reenvía lo que toca el usuario.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  /// Modo pantalla completa (como Música de la Mac): solo carátula,
  /// controles y letra grande, sin menú lateral. HomeShell lo escucha para
  /// esconder el menú.
  static final ValueNotifier<bool> immersive = ValueNotifier(false);

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _messagesSub;
  bool _appInForeground = true;
  late final NowPlayingController _c = ref.read(nowPlayingControllerProvider);

  // --- Barra de progreso arrastrable ---
  bool _seeking = false;
  double _seekValueMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeShell.currentTab.addListener(_updateVisibility);
    SettingsService.keepScreenOn.addListener(_updateVisibility);
    _messagesSub = _c.messages.listen((text) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    });
    _c.addListener(_updateVisibility);
    NowPlayingScreen.immersive.addListener(_onImmersiveChanged);
    MacWindow.fullScreen.addListener(_onFullScreenChanged);
  }

  // ------------------------------------------------- pantalla completa

  /// Si al entrar al modo pantalla completa pusimos la ventana de la Mac en
  /// pantalla completa (para devolverla como estaba al salir).
  bool _enteredWindowFullScreen = false;
  bool _chromeVisible = true;
  Timer? _idleTimer;

  /// Se puede prender desde acá o con ⇧⌘F (HomeShell): en los dos casos
  /// la ventana de la Mac pasa a pantalla completa.
  void _onImmersiveChanged() {
    if (!mounted) return;
    final on = NowPlayingScreen.immersive.value;
    if (on && isMac && !MacWindow.fullScreen.value) {
      _enteredWindowFullScreen = true;
      MacWindow.toggleFullScreen();
    }
    if (!on) {
      _idleTimer?.cancel();
      _chromeVisible = true;
      if (_enteredWindowFullScreen && MacWindow.fullScreen.value) MacWindow.toggleFullScreen();
      _enteredWindowFullScreen = false;
    }
    setState(() {});
    if (on) _poke();
  }

  void _enterImmersive() => NowPlayingScreen.immersive.value = true;

  void _exitImmersive() => NowPlayingScreen.immersive.value = false;

  /// Si salen de la pantalla completa de la Mac (botón verde, ⌃⌘F), también
  /// se sale del modo.
  void _onFullScreenChanged() {
    if (!MacWindow.fullScreen.value &&
        _enteredWindowFullScreen &&
        NowPlayingScreen.immersive.value) {
      _enteredWindowFullScreen = false;
      _exitImmersive();
    }
  }

  /// Los botones se esconden (y el puntero también) si no se mueve el mouse.
  void _poke() {
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _chromeVisible = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    _updateVisibility();
  }

  /// Mantiene la pantalla encendida solo mientras se está viendo la letra
  /// de algo que suena (si está activado en Ajustes), y le avisa al
  /// controlador si la letra está a la vista (para las estadísticas).
  void _updateVisibility() {
    final c = _c;
    final visible = _appInForeground && HomeShell.currentTab.value == 0 && c.lyrics != null;
    c.lyricsVisible = visible;
    final keepOn = SettingsService.keepScreenOn.value && visible && (c.track?.isPlaying ?? false);
    WakelockPlus.toggle(enable: keepOn).catchError((_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HomeShell.currentTab.removeListener(_updateVisibility);
    SettingsService.keepScreenOn.removeListener(_updateVisibility);
    _c.removeListener(_updateVisibility);
    _messagesSub?.cancel();
    _idleTimer?.cancel();
    NowPlayingScreen.immersive.removeListener(_onImmersiveChanged);
    MacWindow.fullScreen.removeListener(_onFullScreenChanged);
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  // ------------------------------------------------------------- acciones

  Future<void> _pickOtherLyrics() async {
    final track = _c.track;
    if (track == null) return;
    final chosen = await showLyricsPicker(
      context,
      title: track.title,
      artist: track.artist,
      durationSeconds: track.duration.inSeconds,
    );
    if (chosen != null && mounted) await _c.useChosenLyrics(chosen);
  }

  Future<void> _openEditor() async {
    final c = _c;
    final track = c.track;
    if (track == null) return;
    final edited = await Navigator.of(context).push<LyricsResult>(
      MaterialPageRoute(
        builder: (_) => LyricsEditorScreen(
          song: track.toSong(),
          initial: c.lyrics,
          livePosition: c.position,
          onSeek: track.fromMicrophone ? null : c.seekTo,
        ),
      ),
    );
    if (edited != null && mounted) await c.useEditedLyrics(edited);
  }

  void _openKaraoke() {
    final c = _c;
    final lyrics = c.lyrics;
    final track = c.track;
    if (lyrics == null || track == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => KaraokeScreen(
          lyrics: lyrics,
          position: c.position,
          offset: c.offset,
          translatedLines: c.translatedLines,
          showTranslation: c.showTranslation,
          artworkBytes: track.albumArt,
        ),
      ),
    );
  }

  Future<void> _recognizeOnce() async {
    final result = await _c.recognizeOnce();
    final lyrics = result?.lyrics;
    if (result == null || lyrics == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LyricsScreen(result: lyrics, originalSong: result.song)),
    );
  }

  void _openSongMenu(NowPlayingTrack track) {
    final c = _c;
    final synced = c.lyrics?.hasSyncedLyrics ?? false;
    showSongActionsSheet(
      context,
      song: track.toSong(),
      artworkBytes: track.albumArt,
      onViewLyrics: c.lyrics == null
          ? null
          : () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LyricsScreen(
                    result: c.lyrics!,
                    livePosition: c.position,
                    originalSong: track.toSong(),
                    onSeek: track.fromMicrophone ? null : c.seekTo,
                    offset: c.offset,
                    artworkBytes: track.albumArt,
                  ),
                ),
              );
            },
      onDownload: (c.lyrics == null || c.saved) ? null : () => c.download(),
      extraActions: [
        SongSheetAction(
          icon: Icons.find_replace_rounded,
          label: '¿Letra equivocada? Elegir otra',
          onTap: _pickOtherLyrics,
        ),
        SongSheetAction(
          icon: Icons.edit_note_rounded,
          label: synced ? 'Corregir o resincronizar la letra' : 'Sincronizar la letra a mano',
          onTap: _openEditor,
        ),
        if (synced)
          SongSheetAction(
            icon: Icons.tune_rounded,
            label: 'Ajustar sincronización',
            onTap: _showOffsetSheet,
          ),
        if (synced)
          SongSheetAction(
            icon: Icons.tv_rounded,
            label: 'Modo karaoke (solo la línea actual)',
            onTap: _openKaraoke,
          ),
      ],
    );
  }

  void _showOffsetSheet() {
    showAdaptiveSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Consumer(builder: (context, ref, _) {
        final c = ref.watch(nowPlayingControllerProvider);
        final track = c.track;
        final canAppOffset =
            track != null && !track.fromMicrophone && track.packageName != null;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Ajustar sincronización',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Si la letra va antes o después que la música, corrígelo aquí.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                _OffsetRow(
                  title: 'Solo esta canción',
                  value: c.songOffset,
                  onChanged: c.setSongOffset,
                ),
                if (canAppOffset) ...[
                  const Divider(height: 28),
                  _OffsetRow(
                    title: 'Todo lo que suena en ${track.sourceAppName ?? 'esta app'}',
                    subtitle: 'Por ejemplo, si usas auriculares Bluetooth con retraso.',
                    value: c.appOffset,
                    onChanged: c.setAppOffset,
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  '"+" = la letra aparece antes',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds <= 0) return '0:00';
    final totalSeconds = d.inSeconds;
    return '${totalSeconds ~/ 60}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(nowPlayingControllerProvider);
    final track = c.track;
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape || isWideLayout(context);
    final showArtBackground = (c.accessGranted || c.continuousMic) && track != null;

    if (NowPlayingScreen.immersive.value) {
      if (track == null) {
        // Se terminó la música: volvemos a la vista normal.
        WidgetsBinding.instance.addPostFrameCallback((_) => _exitImmersive());
      } else {
        return _buildImmersive(c, track);
      }
    }

    return Scaffold(
      extendBodyBehindAppBar: showArtBackground,
      backgroundColor: AppTheme.background,
      appBar: (showArtBackground && landscape)
          ? null
          : AppBar(
              backgroundColor: showArtBackground ? Colors.transparent : null,
              title: const Text('Reproduciendo'),
              actions: _buildAppBarActions(c),
            ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Recortado: la carátula agrandada y difuminada no puede pintar
          // encima del menú lateral.
          if (showArtBackground) ClipRect(child: _ArtBackground(bytes: track.albumArt)),
          SafeArea(
            child: c.checkingPermission
                ? const Center(child: CircularProgressIndicator())
                : (!c.accessGranted && !c.continuousMic)
                    ? _buildPermissionRequest(c)
                    : track == null
                        ? _buildNothingPlaying(c)
                        : landscape
                            ? _buildLandscapeContent(c, track)
                            : _buildPortraitContent(c, track),
          ),
        ],
      ),
    );
  }

  Widget _spinner() => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );

  List<Widget> _buildAppBarActions(NowPlayingController c) {
    final hasLyrics = c.track != null && c.lyrics != null;
    final synced = hasLyrics && c.lyrics!.hasSyncedLyrics;
    final accent = Theme.of(context).colorScheme.primary;
    return [
      if (synced)
        IconButton(
          tooltip: 'Modo karaoke',
          icon: const Icon(Icons.tv_rounded),
          onPressed: _openKaraoke,
        ),
      if (synced)
        IconButton(
          tooltip: c.showTranslation ? 'Ocultar traducción' : 'Traducir',
          icon: c.translating
              ? _spinner()
              : Icon(Icons.translate_rounded, color: c.showTranslation ? accent : null),
          onPressed: c.translating ? null : c.toggleTranslation,
        ),
      if (hasLyrics)
        IconButton(
          tooltip: c.saved ? 'Ya descargada' : 'Descargar letra',
          icon: c.saving
              ? _spinner()
              : Icon(c.saved ? Icons.download_done_rounded : Icons.download_rounded),
          onPressed: (c.saved || c.saving) ? null : () => c.download(),
        ),
      PopupMenuButton<String>(
        tooltip: 'Micrófono',
        icon: c.recognizing
            ? _spinner()
            : Icon(Icons.mic_rounded, color: c.continuousMic ? accent : null),
        onSelected: (v) {
          if (v == 'once') _recognizeOnce();
          if (v == 'continuous') c.toggleContinuousMic();
        },
        itemBuilder: (_) => [
          if (!c.continuousMic)
            const PopupMenuItem(value: 'once', child: Text('Reconocer esta canción')),
          PopupMenuItem(
            value: 'continuous',
            child: Text(
              c.continuousMic ? 'Dejar de escuchar' : 'Escuchar sin parar (canción tras canción)',
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildPermissionRequest(NowPlayingController c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_active_rounded,
                size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            const Text(
              'Para detectar automáticamente lo que estás escuchando, la app '
              'necesita acceso a las notificaciones (así puede leer qué app '
              'de música está sonando).',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 8),
            const Text(
              'Al tocar el botón se abre la lista de apps con acceso a '
              'notificaciones: busca "Letras" y actívala. Después vuelve aquí.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: c.openNotificationAccessSettings,
              child: const Text('Dar acceso'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: c.toggleContinuousMic,
              icon: const Icon(Icons.hearing_rounded),
              label: const Text('O escuchar con el micrófono'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNothingPlaying(NowPlayingController c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              c.continuousMic ? Icons.hearing_rounded : Icons.music_off_rounded,
              size: 56,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              c.continuousMic
                  ? 'Escuchando con el micrófono...\nCuando reconozca la canción, aparece la letra.'
                  : 'No se está reproduciendo nada ahora mismo.\n'
                      'Reproduce algo en Spotify, YouTube Music, etc.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 16),
            ),
            const SizedBox(height: 24),
            if (!c.continuousMic)
              ElevatedButton.icon(
                onPressed: c.recognizing ? null : _recognizeOnce,
                icon: c.recognizing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.mic_rounded),
                label: Text(c.recognizing ? 'Escuchando...' : 'Reconocer con micrófono'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: c.toggleContinuousMic,
              icon: Icon(c.continuousMic ? Icons.stop_rounded : Icons.hearing_rounded),
              label: Text(c.continuousMic ? 'Dejar de escuchar' : 'Escuchar sin parar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricsArea(NowPlayingController c, {required bool compact, double sizeBoost = 1}) {
    if (c.loadingLyrics) {
      return const Center(child: CircularProgressIndicator(color: Colors.white70));
    }
    if (c.lyricsError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                c.lyricsError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: c.retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Reintentar'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickOtherLyrics,
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Buscar a mano'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openEditor,
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('Escribirla y sincronizarla'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final track = c.track!;
    return SyncedLyricsView(
      lines: c.lyrics?.syncedLyrics ?? const [],
      position: c.position,
      plainLyricsFallback: c.lyrics?.plainLyrics ?? '',
      showTranslation: c.showTranslation,
      translatedLines: c.translatedLines,
      romanizedLines: c.romanizedLines,
      offset: c.offset,
      onSeek: track.fromMicrophone ? null : c.seekTo,
      song: track.toSong(),
      artworkBytes: track.albumArt,
      showSearchButton: !compact,
      sizeBoost: sizeBoost,
    );
  }

  /// Si suenan dos apps a la vez, chips para elegir cuál seguir.
  Widget _buildPlayerChooser(NowPlayingController c, NowPlayingTrack track) {
    final players = track.players;
    if (players.length < 2 || track.fromMicrophone) return const SizedBox.shrink();
    final preferred = SettingsService.preferredPackage.value;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: const Text('Automático'),
              selected: preferred == null,
              onSelected: (_) => c.choosePlayer(null),
            ),
          ),
          for (final p in players)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                avatar: Icon(
                  p.isPlaying ? Icons.graphic_eq_rounded : Icons.pause_rounded,
                  size: 16,
                ),
                label: Text(p.appName),
                tooltip: '${p.title} — ${p.artist}',
                selected: preferred == p.packageName,
                onSelected: (_) => c.choosePlayer(p.packageName),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPortraitContent(NowPlayingController c, NowPlayingTrack track) {
    return Column(
      children: [
        InkWell(
          onTap: () => _openSongMenu(track),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
            child: Row(
              children: [
                ArtworkThumb(
                  title: track.title,
                  artist: track.artist,
                  bytes: track.albumArt,
                  size: 56,
                  borderRadius: 10,
                ),
                const SizedBox(width: 14),
                Expanded(child: _TrackTitle(track: track)),
                IconButton(
                  icon: const Icon(Icons.more_horiz_rounded, color: Colors.white70),
                  onPressed: () => _openSongMenu(track),
                ),
              ],
            ),
          ),
        ),
        _buildPlayerChooser(c, track),
        Expanded(child: _buildLyricsArea(c, compact: false)),
        _buildTransport(c, track, compact: true),
      ],
    );
  }

  /// Barra de progreso arrastrable + controles reales de la app de música.
  /// Si la canción viene del micrófono, no hay nada que controlar.
  Widget _buildTransport(NowPlayingController c, NowPlayingTrack track, {required bool compact}) {
    final accent = Theme.of(context).colorScheme.primary;
    final hasSynced = c.lyrics?.hasSyncedLyrics ?? false;
    final hasOffset = c.offset != Duration.zero;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 0, 0, compact ? 16 : 0, compact ? 6 : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: c.position,
            initialData: track.estimatedPositionNow(),
            builder: (context, snapshot) {
              final duration = track.duration;
              final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 0.0;
              final livePosition = (snapshot.data ?? Duration.zero)
                  .inMilliseconds
                  .toDouble()
                  .clamp(0.0, maxMs == 0 ? 0.0 : maxMs)
                  .toDouble();
              final displayedMs = _seeking ? _seekValueMs : livePosition;
              final canSeek = maxMs > 0 && !track.fromMicrophone;

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: SizedBox(
                      height: 28,
                      child: Slider(
                        value: displayedMs.clamp(0.0, maxMs == 0 ? 1.0 : maxMs).toDouble(),
                        max: maxMs > 0 ? maxMs : 1.0,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: canSeek
                            ? (v) => setState(() {
                                  _seeking = true;
                                  _seekValueMs = v;
                                })
                            : null,
                        onChangeEnd: canSeek
                            ? (v) {
                                c.seekTo(Duration(milliseconds: v.round()));
                                setState(() => _seeking = false);
                              }
                            : null,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(Duration(milliseconds: displayedMs.round())),
                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        Text(
                          '-${_formatDuration(Duration(milliseconds: (maxMs - displayedMs).round()))}',
                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: 'Ajustar sincronización',
                icon: Icon(Icons.tune_rounded, color: hasOffset ? accent : Colors.white54),
                onPressed: hasSynced ? _showOffsetSheet : null,
              ),
              if (track.fromMicrophone) ...[
                const Icon(Icons.hearing_rounded, color: Colors.white70),
                TextButton(
                  onPressed: c.toggleContinuousMic,
                  child: const Text('Dejar de escuchar'),
                ),
              ] else ...[
                IconButton(
                  iconSize: 34,
                  icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                  onPressed: c.skipPrevious,
                ),
                IconButton(
                  iconSize: compact ? 52 : 46,
                  icon: Icon(
                    track.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                    color: Colors.white,
                  ),
                  onPressed: c.togglePlayPause,
                ),
                IconButton(
                  iconSize: 34,
                  icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                  onPressed: c.skipNext,
                ),
              ],
              IconButton(
                tooltip: c.showTranslation ? 'Ocultar traducción' : 'Traducir',
                icon: Icon(
                  Icons.translate_rounded,
                  color: c.showTranslation ? accent : Colors.white54,
                ),
                onPressed: hasSynced && !c.translating ? c.toggleTranslation : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Diseño horizontal tipo Apple Music (teléfono acostado, o la Mac):
  /// carátula grande con título y controles debajo, todo centrado a la
  /// izquierda, y la letra a la derecha sobre el fondo difuminado.
  Widget _buildLandscapeContent(NowPlayingController c, NowPlayingTrack track) {
    return LayoutBuilder(builder: (context, box) {
      final roomy = box.maxWidth >= 900;
      final panelWidth = (box.maxWidth * 0.38).clamp(300.0, 480.0);
      // La carátula crece con la ventana, pero deja lugar para título y controles.
      final artSize = math.min(panelWidth - 64, box.maxHeight - 250).clamp(110.0, 420.0);
      final columnWidth = math.max(artSize, 280.0);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: panelWidth,
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(roomy ? 40 : 24, 12, roomy ? 24 : 16, 12),
                child: SizedBox(
                  width: columnWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _openSongMenu(track),
                          child: _CoverArt(track: track, size: artSize),
                        ),
                      ),
                      SizedBox(height: roomy ? 28 : 16),
                      Row(
                        children: [
                          Expanded(child: _TrackTitle(track: track, large: roomy)),
                          IconButton(
                            tooltip: c.saved ? 'Ya descargada' : 'Descargar letra',
                            icon: c.saving
                                ? _spinner()
                                : Icon(
                                    c.saved ? Icons.download_done_rounded : Icons.download_rounded,
                                    color: Colors.white70,
                                  ),
                            onPressed: (c.lyrics == null || c.saved || c.saving)
                                ? null
                                : () => c.download(),
                          ),
                          _buildAppBarActions(c).last, // micrófono
                          if (roomy)
                            IconButton(
                              tooltip: 'Pantalla completa (⇧⌘F)',
                              icon: const Icon(Icons.open_in_full_rounded, color: Colors.white70),
                              onPressed: _enterImmersive,
                            ),
                          IconButton(
                            tooltip: 'Más opciones',
                            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white70),
                            onPressed: () => _openSongMenu(track),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _buildTransport(c, track, compact: false),
                      if (track.players.length > 1 && !track.fromMicrophone) ...[
                        const SizedBox(height: 8),
                        _buildPlayerChooser(c, track),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: roomy ? 32 : 8),
              child: _buildLyricsArea(c, compact: true),
            ),
          ),
        ],
      );
    });
  }

  /// Pantalla completa estilo Música: carátula y controles a la izquierda,
  /// letra enorme a la derecha, fondo que se mueve despacio. Esc sale.
  Widget _buildImmersive(NowPlayingController c, NowPlayingTrack track) {
    final size = MediaQuery.sizeOf(context);
    final artSize = math.min(size.width * 0.3, size.height * 0.52).clamp(200.0, 620.0);
    final chrome = _chromeVisible;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _exitImmersive,
        SingleActivator(LogicalKeyboardKey.keyF, meta: isMac, control: !isMac, shift: true):
            _exitImmersive,
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          cursor: chrome ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => _poke(),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(child: _ArtBackground(bytes: track.albumArt, animated: true)),
                Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: SizedBox(
                            width: artSize,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _CoverArt(track: track, size: artSize),
                                const SizedBox(height: 26),
                                Row(
                                  children: [
                                    Expanded(child: _TrackTitle(track: track, large: true)),
                                    AnimatedOpacity(
                                      opacity: chrome ? 1 : 0,
                                      duration: const Duration(milliseconds: 300),
                                      child: _GlassButton(
                                        icon: Icons.more_horiz_rounded,
                                        tooltip: 'Más opciones',
                                        onPressed: () => _openSongMenu(track),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _buildTransport(c, track, compact: false),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 48),
                        child: _buildLyricsArea(c, compact: true, sizeBoost: 1.45),
                      ),
                    ),
                  ],
                ),
                // Salir, arriba a la izquierda (al lado de donde aparecen los
                // tres botones de la ventana).
                Positioned(
                  top: 18,
                  left: 22,
                  child: AnimatedOpacity(
                    opacity: chrome ? 1 : 0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: !chrome,
                      child: _GlassButton(
                        icon: Icons.close_fullscreen_rounded,
                        tooltip: 'Salir de pantalla completa (Esc)',
                        onPressed: _exitImmersive,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Botón redondo translúcido, como los de Música en pantalla completa.
class _GlassButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _GlassButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Carátula grande con sombra, que cambia con un fundido.
class _CoverArt extends StatelessWidget {
  final NowPlayingTrack track;
  final double size;

  const _CoverArt({required this.track, required this.size});

  @override
  Widget build(BuildContext context) {
    final radius = size >= 240 ? 14.0 : 10.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 18)),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: ArtworkThumb(
          key: ValueKey('${track.title}|${track.artist}'),
          title: track.title,
          artist: track.artist,
          bytes: track.albumArt,
          size: size,
          borderRadius: radius,
        ),
      ),
    );
  }
}

/// Fila de ajuste de desfase: -1s / -0.25 / restablecer / +0.25 / +1s.
class _OffsetRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Duration value;
  final ValueChanged<Duration> onChanged;

  const _OffsetRow({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  void _change(int deltaMs) =>
      onChanged(Duration(milliseconds: (value.inMilliseconds + deltaMs).clamp(-10000, 10000)));

  Widget _button(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(56, 40),
          ),
          onPressed: onTap,
          child: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final seconds = value.inMilliseconds / 1000;
    final label = seconds == 0
        ? 'Sin desfase'
        : '${seconds > 0 ? '+' : ''}${seconds.toStringAsFixed(2)} s '
            '${seconds > 0 ? '(adelantada)' : '(atrasada)'}';
    return Column(
      children: [
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 8),
        FittedBox(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _button('-1s', () => _change(-1000)),
              _button('-0.25', () => _change(-250)),
              IconButton(
                tooltip: 'Restablecer',
                icon: const Icon(Icons.restart_alt_rounded),
                onPressed: () => onChanged(Duration.zero),
              ),
              _button('+0.25', () => _change(250)),
              _button('+1s', () => _change(1000)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Título + artista + de dónde viene ("en Spotify", "por el micrófono").
class _TrackTitle extends StatelessWidget {
  final NowPlayingTrack track;
  final bool large;

  const _TrackTitle({required this.track, this.large = false});

  @override
  Widget build(BuildContext context) {
    final source = track.sourceAppName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 22 : 18,
            fontWeight: FontWeight.w700,
            letterSpacing: large ? -0.3 : 0,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          source == null
              ? track.artist
              : '${track.artist} · ${track.fromMicrophone ? 'por' : 'en'} $source',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: large ? 15 : 14, color: Colors.white70),
        ),
      ],
    );
  }
}

/// Fondo con la carátula muy difuminada y oscurecida, como en Apple Music.
/// Cambia con un fundido suave cuando cambia la canción. Con [animated]
/// (pantalla completa) la imagen gira y respira despacio, como en Música.
class _ArtBackground extends StatefulWidget {
  final Uint8List? bytes;
  final bool animated;

  const _ArtBackground({this.bytes, this.animated = false});

  @override
  State<_ArtBackground> createState() => _ArtBackgroundState();
}

class _ArtBackgroundState extends State<_ArtBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _motion =
      AnimationController(vsync: this, duration: const Duration(seconds: 40));

  @override
  void initState() {
    super.initState();
    if (widget.animated) _motion.repeat();
  }

  @override
  void didUpdateWidget(covariant _ArtBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_motion.isAnimating) _motion.repeat();
    if (!widget.animated && _motion.isAnimating) _motion.stop();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final art = widget.bytes;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 700),
      child: art == null
          ? Container(
              key: const ValueKey('no-art'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(Theme.of(context).colorScheme.primary, Colors.black, 0.75)!,
                    AppTheme.background,
                  ],
                ),
              ),
            )
          : Stack(
              key: ObjectKey(art),
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter:
                      ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.mirror),
                  child: AnimatedBuilder(
                    animation: _motion,
                    builder: (context, child) {
                      final t = _motion.value * 2 * math.pi;
                      return Transform.rotate(
                        angle: widget.animated ? t : 0,
                        child: Transform.scale(
                          scale: widget.animated ? 1.9 + 0.15 * math.sin(t * 2) : 1.4,
                          child: child,
                        ),
                      );
                    },
                    child: Image.memory(art, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        // Un poco más oscuro: con carátulas claras la letra
                        // de las líneas apagadas casi no se leía.
                        Colors.black.withValues(alpha: 0.45),
                        Colors.black.withValues(alpha: 0.6),
                        Colors.black.withValues(alpha: 0.78),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
