import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../services/accent_controller.dart';
import '../services/genius_service.dart';
import '../services/history_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/artwork_thumb.dart';
import '../widgets/lyrics_picker_sheet.dart';
import '../widgets/song_info_view.dart';
import '../widgets/synced_lyrics_view.dart';
import 'karaoke_screen.dart';
import 'lyrics_editor_screen.dart';
import 'settings_screen.dart';
import '../providers.dart';

/// Pantalla que muestra la letra de una canción con la animación tipo
/// Apple Music.
///
/// Si [livePosition] viene desde la detección de "reproduciendo ahora"
/// (NowPlayingService), la letra se sincroniza en tiempo real con la
/// canción que suena en Spotify/YouTube Music/etc.
///
/// Si no hay [livePosition] (por ejemplo, viniendo del buscador manual o
/// de las descargas), se muestra un modo "vista previa" con un botón de
/// play/pause propio para poder ver la animación igual.
class LyricsScreen extends ConsumerStatefulWidget {
  final LyricsResult result;
  final Stream<Duration>? livePosition;

  /// Identidad "de origen" de la canción (la que detectó Now Playing, la
  /// de Spotify, o la que reconoció el micrófono), si esta pantalla se
  /// abrió a partir de una de esas fuentes. Si se pasa, se usa para
  /// guardar/chequear la descarga en vez de `result.song` (que viene de
  /// LRCLIB y puede tener el título/artista levemente distinto) — así el
  /// "¿ya la tengo descargada?" siempre compara contra lo mismo.
  final Song? originalSong;

  /// Si la letra está sincronizada con lo que suena de verdad, tocar una
  /// línea salta ahí en la app de música.
  final ValueChanged<Duration>? onSeek;

  /// Desfase de sincronización a aplicar (el mismo que en Reproduciendo).
  final Duration offset;

  /// Carátula ya conocida (para compartir tarjetas con la letra).
  final Uint8List? artworkBytes;

  /// Si viene (búsqueda dentro de las descargas), abre con el buscador de
  /// la letra cargado con este texto y la línea resaltada.
  final String? highlightQuery;

  const LyricsScreen({
    super.key,
    required this.result,
    this.livePosition,
    this.originalSong,
    this.onSeek,
    this.offset = Duration.zero,
    this.artworkBytes,
    this.highlightQuery,
  });

  @override
  ConsumerState<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends ConsumerState<LyricsScreen> {
  late final _storage = ref.read(storageProvider);
  late final _translationService = ref.read(translationProvider);
  late final _artworkService = ref.read(artworkProvider);
  late final _geniusService = ref.read(geniusProvider);
  late final _settingsService = ref.read(settingsProvider);

  // --- Sección "Info" (Letra / Info), cargada recién al abrirla la
  // primera vez, así no gastamos una llamada a Genius si el usuario nunca
  // toca esa pestaña. ---
  bool _showInfoTab = false;
  bool _infoRequested = false;
  bool _loadingInfo = false;
  bool _geniusTokenMissing = false;
  SongInfo? _songInfo;

  // --- Reloj manual para el modo "vista previa" (sin reproducción real) ---
  final StreamController<Duration> _manualClockController =
      StreamController<Duration>.broadcast();
  Timer? _manualTimer;
  Duration _manualPosition = Duration.zero;
  bool _manualPlaying = false;

  bool _saved = false;
  bool _saving = false;

  bool _showTranslation = false;
  List<String>? _translatedLines;
  List<String>? _romanizedLines;
  bool _translating = false;
  Future<List<String>?>? _translationFuture;
  TranslationCancelToken? _translationCancel;

  /// Avisa al karaoke abierto desde aquí cada vez que cambia algo.
  final ValueNotifier<int> _karaokeUpdates = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _karaokeUpdates.value++;
  }

  bool get _isLive => widget.livePosition != null;

  // La letra mostrada puede cambiar si el usuario elige otra a mano.
  late LyricsResult _result = widget.result;
  Uint8List? _artworkBytes;
  Duration _offset = Duration.zero;

  // El acento que había antes de abrir esta letra, para devolverlo al salir.
  final Color _previousAccent = AccentController.color.value;

  /// La identidad a usar para guardar/chequear la descarga: la "de
  /// origen" si la tenemos, si no la de la letra en sí.
  Song get _identitySong => widget.originalSong ?? widget.result.song;

  @override
  void initState() {
    super.initState();
    // Si la letra viene de una descarga, la traducción ya puede estar
    // guardada ahí mismo: no hace falta pedirla de nuevo por red.
    // Solo si tiene tantas líneas como la letra: si no, quedaría corrida.
    _translatedLines = widget.result.translationLang == SettingsService.translationLang.value
        ? TranslationService.alignedTo(
            widget.result.translatedLines, widget.result.syncedLyrics.length)
        : null;
    _romanizedLines = widget.result.romanizedLines;
    _loadRomanization();
    _offset = widget.offset;
    _artworkBytes = widget.artworkBytes;
    _checkSaved();
    HistoryService().add(_identitySong);
    if (_artworkBytes == null) {
      _loadArtwork();
    } else {
      AccentController.updateFromArtwork(_artworkBytes);
    }
    if (!_isLive) {
      _settingsService.getSyncOffset(_identitySong.title, _identitySong.artist).then((o) {
        if (mounted) setState(() => _offset = o);
      });
    }
    if (SettingsService.keepScreenOn.value) WakelockPlus.enable().catchError((_) {});
  }

  /// Carátula para compartir y para el encabezado: primero la guardada,
  /// si no la de iTunes/Spotify (cacheada).
  Future<void> _loadArtwork() async {
    final song = _identitySong;
    final bytes = await _storage.getArtworkBytes(song.title, song.artist) ??
        await _artworkService.fetchArtworkBytes(song.title, song.artist,
            knownUrl: song.artworkUrl, album: song.album, durationSeconds: song.durationSeconds);
    if (mounted && bytes != null) {
      setState(() => _artworkBytes = bytes);
      AccentController.updateFromArtwork(bytes);
    }
  }

  void _openKaraoke() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => KaraokeScreen(
          lyrics: _result,
          position: widget.livePosition ?? _manualClockController.stream,
          offset: _isLive ? _offset : Duration.zero,
          translatedLines: _translatedLines,
          showTranslation: _showTranslation,
          artworkBytes: _artworkBytes,
          updates: _karaokeUpdates,
          liveContent: () => KaraokeContent(
            lyrics: _result,
            translatedLines: _translatedLines,
            showTranslation: _showTranslation,
            offset: _isLive ? _offset : Duration.zero,
          ),
        ),
      ),
    );
    if (!_isLive && !_manualPlaying) _toggleManualPlayback();
  }

  /// Elegir otra letra (si la encontrada no era la correcta). Si esta
  /// canción estaba descargada, se reemplaza por la nueva.
  Future<void> _pickOtherLyrics() async {
    final identity = _identitySong;
    final chosen = await showLyricsPicker(
      context,
      title: identity.title,
      artist: identity.artist,
      durationSeconds: identity.durationSeconds ?? _result.song.durationSeconds,
    );
    if (chosen == null || !mounted) return;
    final wasSaved = _saved;
    setState(() {
      _result = chosen;
      _resetTranslation();
      _romanizedLines = null;
      _saved = false;
      _manualPosition = Duration.zero;
    });
    if (_showTranslation) _ensureTranslation();
    _loadRomanization();
    if (wasSaved) await _download();
  }

  /// Pronunciación en letras latinas (japonés, coreano, ruso...), si está
  /// prendida en Ajustes y hace falta.
  Future<void> _loadRomanization() async {
    if (_romanizedLines != null || !SettingsService.showRomanization.value) return;
    final current = _result;
    final roman = await _translationService.romanize(current.displayLines);
    if (mounted && identical(current, _result) && roman != null) {
      setState(() => _romanizedLines = TranslationService.alignedTo(roman, current.displayLines.length));
    }
  }

  /// Corregir la letra o sincronizarla a mano (y opcionalmente subirla a
  /// LRCLIB). La editada reemplaza a la descargada, si estaba.
  Future<void> _openEditor() async {
    final edited = await Navigator.of(context).push<LyricsResult>(
      MaterialPageRoute(
        builder: (_) => LyricsEditorScreen(
          song: _identitySong,
          initial: _result,
          livePosition: widget.livePosition,
          onSeek: widget.onSeek,
        ),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      _result = edited;
      _resetTranslation();
      _romanizedLines = null;
      _manualPosition = Duration.zero;
    });
    if (_showTranslation) _ensureTranslation();
    _loadRomanization();
    await _download();
  }

  /// En modo vista previa, tocar una línea mueve el reloj propio ahí.
  void _manualSeek(Duration position) {
    _manualPosition = position;
    _manualClockController.add(position);
    if (!_manualPlaying) _toggleManualPlayback();
  }

  /// Descarta la traducción de la letra anterior (lo pendiente se cancela).
  void _resetTranslation() {
    _translationCancel?.cancel();
    _translationCancel = null;
    _translationFuture = null;
    _translatedLines = null;
    _translating = false;
  }

  /// Pide la traducción si todavía no la tenemos (ni en memoria ni
  /// guardada), una sola vez: si ya hay un pedido en curso, devuelve ese.
  /// Devuelve la lista (vacía si ya está en el idioma elegido) o `null` si
  /// falló. Si la IA está activada, primero se ve la automática.
  Future<List<String>?> _ensureTranslation() {
    if (_translatedLines != null && !_translating) return Future.value(_translatedLines);
    final pending = _translationFuture;
    if (pending != null) return pending;
    final current = _result;
    if (!current.hasSyncedLyrics) return Future.value(null);

    final cancel = TranslationCancelToken();
    _translationCancel = cancel;
    final texts = current.syncedLyrics.map((l) => l.text).toList();
    setState(() => _translating = true);
    bool stillCurrent() => mounted && !cancel.isCancelled && identical(current, _result);

    final future = () async {
      List<String>? result;
      try {
        await for (final update in _translationService.translateLive(
          texts,
          title: current.song.title,
          artist: current.song.artist,
          cancel: cancel,
        )) {
          if (!stillCurrent()) return null;
          final aligned = TranslationService.alignedTo(update.lines, texts.length);
          if (aligned != null) setState(() => _translatedLines = aligned);
          if (update.isFinal) result = aligned;
        }
      } catch (_) {}
      if (!stillCurrent()) return null;
      setState(() {
        _translating = false;
        _translationFuture = null;
      });
      return result ?? _translatedLines;
    }();
    _translationFuture = future;
    return future;
  }

  Future<void> _toggleTranslation() async {
    setState(() => _showTranslation = !_showTranslation);
    if (!_showTranslation || _translatedLines != null) return;
    final current = _result;
    final translated = await _ensureTranslation();
    if (!mounted || !identical(current, _result)) return;
    if (translated == null) {
      // Falló de verdad (sin conexión, o el traductor está saturado) — no
      // lo confundimos con "ya está en español". Mientras, se ve la letra
      // original.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo traducir ahora (sin conexión o el traductor está saturado). '
            'Toca "Traducir" de nuevo en un rato.',
          ),
        ),
      );
      setState(() => _showTranslation = false);
    } else if (translated.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Esta letra ya parece estar en el idioma elegido.')),
      );
    }
  }

  Future<void> _checkSaved() async {
    final saved = await _storage.isSaved(_identitySong.title, _identitySong.artist);
    if (mounted) setState(() => _saved = saved);
  }

  void _selectTab({required bool showInfo}) {
    if (_showInfoTab == showInfo) return;
    setState(() => _showInfoTab = showInfo);
    if (showInfo) _loadInfoIfNeeded();
  }

  Future<void> _loadInfoIfNeeded() async {
    if (_infoRequested) return;
    _infoRequested = true;
    setState(() => _loadingInfo = true);
    final token = await _settingsService.getGeniusToken();
    if (token.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _loadingInfo = false;
          _geniusTokenMissing = true;
        });
      }
      return;
    }
    final identity = _identitySong;
    final info = await _geniusService.fetchSongInfo(
      apiToken: token,
      title: identity.title,
      artist: identity.artist,
    );
    if (mounted) {
      setState(() {
        _loadingInfo = false;
        _songInfo = info;
      });
    }
  }

  void _openGeniusSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _toggleManualPlayback() {
    setState(() => _manualPlaying = !_manualPlaying);
    if (_manualPlaying) {
      _manualTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _manualPosition += const Duration(milliseconds: 100);
        _manualClockController.add(_manualPosition);
      });
    } else {
      _manualTimer?.cancel();
    }
  }

  Future<void> _download() async {
    setState(() => _saving = true);
    try {
      // Bajamos también la traducción y la carátula para que quede todo
      // disponible sin conexión (si todavía no las teníamos). Guardamos
      // con la identidad "de origen": así el chequeo "¿ya la tengo?" la
      // encuentra la próxima vez, sin importar si LRCLIB devolvió el
      // título/artista con alguna pequeña diferencia.
      final identity = _identitySong;
      final translated = await _ensureTranslation();
      final artwork = _artworkBytes ?? await _artworkService.fetchArtworkBytes(
        identity.title,
        identity.artist,
        knownUrl: identity.artworkUrl,
        album: identity.album,
        durationSeconds: identity.durationSeconds,
      );
      await _storage.save(
        _result.copyWith(
          translatedLines: translated,
          translationLang: translated == null ? null : SettingsService.translationLang.value,
          romanizedLines: _romanizedLines,
          song: _result.song.withIdentityFrom(identity),
        ),
        artworkBytes: artwork,
      );
      if (!mounted) return;
      setState(() {
        _saved = true;
        _saving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Letra descargada. Ya la puedes ver sin conexión.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo descargar: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _translationCancel?.cancel();
    _karaokeUpdates.dispose();
    _manualTimer?.cancel();
    _manualClockController.close();
    WakelockPlus.disable().catchError((_) {});
    AccentController.color.value = _previousAccent;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = _identitySong;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArtworkThumb(
              title: song.title,
              artist: song.artist,
              bytes: _artworkBytes,
              imageUrl: song.artworkUrl,
              size: 40,
              borderRadius: 8,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title.isEmpty ? '(Sin título)' : song.title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    song.artist,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_result.hasSyncedLyrics)
            IconButton(
              tooltip: _showTranslation ? 'Ocultar traducción' : 'Traducir',
              icon: _translating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.translate_rounded,
                      color: _showTranslation ? Theme.of(context).colorScheme.primary : null,
                    ),
              onPressed: _toggleTranslation,
            ),
          IconButton(
            tooltip: _saved ? 'Ya descargada' : 'Descargar letra',
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_saved ? Icons.download_done_rounded : Icons.download_rounded),
            onPressed: (_saved || _saving) ? null : _download,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pick') _pickOtherLyrics();
              if (v == 'karaoke') _openKaraoke();
              if (v == 'edit') _openEditor();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'pick', child: Text('¿Letra equivocada? Elegir otra')),
              PopupMenuItem(
                value: 'edit',
                child: Text(_result.hasSyncedLyrics
                    ? 'Corregir o resincronizar'
                    : 'Sincronizar a mano'),
              ),
              if (_result.hasSyncedLyrics)
                const PopupMenuItem(value: 'karaoke', child: Text('Modo karaoke (pantalla completa)')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Center(child: _buildTabSwitch()),
          ),
        ),
      ),
      body: _showInfoTab
          ? SongInfoView(
              song: _identitySong,
              loading: _loadingInfo,
              tokenMissing: _geniusTokenMissing,
              info: _songInfo,
              onOpenSettings: _openGeniusSettings,
            )
          : SyncedLyricsView(
              lines: _result.syncedLyrics,
              position: widget.livePosition ?? _manualClockController.stream,
              plainLyricsFallback: _result.plainLyrics,
              showTranslation: _showTranslation,
              translatedLines: _translatedLines,
              romanizedLines: _romanizedLines,
              initialSearchQuery: widget.highlightQuery,
              offset: _isLive ? _offset : Duration.zero,
              onSeek: _isLive ? widget.onSeek : _manualSeek,
              song: _identitySong,
              artworkBytes: _artworkBytes,
            ),
      floatingActionButton: (!_showInfoTab && !_isLive && _result.hasSyncedLyrics)
          ? FloatingActionButton(
              onPressed: _toggleManualPlayback,
              child: Icon(_manualPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
            )
          : null,
    );
  }

  /// Interruptor tipo "segmented control" (Letra / Info) para interactuar
  /// con la canción más allá de solo verla pasar: la letra en sí, o una
  /// sección con datos de qué habla, quién la escribió, etc.
  Widget _buildTabSwitch() {
    Widget segment(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment('Letra', !_showInfoTab, () => _selectTab(showInfo: false)),
          segment('Info', _showInfoTab, () => _selectTab(showInfo: true)),
        ],
      ),
    );
  }
}
