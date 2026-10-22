import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/lyric_line.dart';
import '../models/song.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../utils/text_normalize.dart';
import '../utils/vocal_parts.dart';
import 'lyric_share_sheet.dart';

/// Widget que muestra la letra con la animación estilo Apple Music:
/// la línea actual se ilumina (con un relleno tipo karaoke que avanza
/// mientras se canta), las anteriores quedan tenues, y la lista se
/// desplaza suavemente para mantener la línea activa a la altura de la
/// vista.
///
/// - Si la letra trae tiempos por palabra, el karaoke va palabra por
///   palabra exacto; si no, se estima según el largo de la línea.
/// - Los coros/segundas voces (lo que va entre paréntesis) se muestran
///   más chicos y a la derecha, debajo de la voz principal.
/// - Las líneas lejanas a la actual se desenfocan levemente.
/// - Las líneas pueden ocupar los renglones que necesiten.
/// - Los silencios/instrumentales se muestran como tres puntitos que se
///   van llenando, igual que en Apple Music.
/// - Tocar una línea salta a ese momento de la canción (si hay [onSeek]).
/// - Mantener apretada una línea abre opciones para copiarla o
///   compartirla (como texto o como tarjeta-imagen).
///
/// Con [focusMode] se muestra solo la línea actual, enorme (para karaoke
/// en la tele), y la siguiente chiquita abajo.
///
/// Si el usuario scrollea manualmente, se deja de seguir la canción
/// automáticamente y aparece un botón para volver a engancharse.
class SyncedLyricsView extends StatefulWidget {
  final List<LyricLine> lines;

  /// Emite la posición actual de reproducción (se recomienda una emisión
  /// cada ~100-200ms; entre emisiones se interpola para que el karaoke
  /// avance fluido).
  final Stream<Duration> position;

  /// Se muestra si no hay letra sincronizada disponible.
  final String plainLyricsFallback;

  /// Traducción línea por línea (mismo orden y cantidad que [lines]).
  final List<String>? translatedLines;

  /// Si mostrar o no la traducción debajo de cada línea.
  final bool showTranslation;

  /// Pronunciación en letras latinas (mismo orden y cantidad que [lines]).
  /// Se muestra si está prendido en Ajustes.
  final List<String>? romanizedLines;

  /// Se suma a la posición recibida: positivo = la letra se adelanta.
  final Duration offset;

  /// Si se pasa, tocar una línea salta a ese momento de la canción.
  final ValueChanged<Duration>? onSeek;

  /// Datos de la canción para compartir líneas.
  final Song? song;
  final Uint8List? artworkBytes;

  /// Muestra o no el botón de búsqueda dentro de la letra.
  final bool showSearchButton;

  /// Solo la línea actual, enorme.
  final bool focusMode;

  /// Agranda la letra (pantalla completa).
  final double sizeBoost;

  /// Si viene, la vista abre con el buscador ya cargado con este texto y
  /// resalta la primera línea que coincide (búsqueda desde Descargas).
  final String? initialSearchQuery;

  const SyncedLyricsView({
    super.key,
    required this.lines,
    required this.position,
    this.plainLyricsFallback = '',
    this.translatedLines,
    this.showTranslation = false,
    this.romanizedLines,
    this.offset = Duration.zero,
    this.onSeek,
    this.song,
    this.artworkBytes,
    this.showSearchButton = true,
    this.focusMode = false,
    this.sizeBoost = 1,
    this.initialSearchQuery,
  });

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

/// El tamaño de letra más grande con el que [text] entra en la caja del
/// modo karaoke. También achica hasta que la palabra más larga entre entera
/// en una línea: si no, Flutter la parte al medio ("ev / erybody").
double fitFocusFontSize(
  String text, {
  required double maxWidth,
  required double maxHeight,
  required double maxSize,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  var size = maxSize;
  while (size > 22) {
    final style = TextStyle(fontSize: size, fontWeight: FontWeight.w800, height: 1.15);
    TextPainter painter(String t) => TextPainter(
          text: TextSpan(text: t, style: style),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          textScaler: textScaler,
        );
    final wordsFit = words.every((w) => (painter(w)..layout()).width <= maxWidth);
    final tp = painter(text)..layout(maxWidth: maxWidth);
    if (wordsFit && tp.height <= maxHeight) return size;
    size *= 0.9;
  }
  return size;
}

/// Una línea "vacía" o de solo símbolos musicales es un instrumental.
bool _isInterlude(String text) {
  final t = text.replaceAll(RegExp(r'[♪♫♬♩\s.…·*-]'), '');
  return t.isEmpty;
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> with SingleTickerProviderStateMixin {
  // Dónde queda la línea actual dentro de la vista (0 = arriba, 1 = abajo).
  static const double _anchor = 0.32;

  /// Línea bajo el mouse (en la compu).
  int? _hoveredLine;

  final ScrollController _scrollController = ScrollController();
  StreamSubscription<Duration>? _sub;
  int _currentIndex = -1;
  List<GlobalKey> _itemKeys = [];
  final GlobalKey _introKey = GlobalKey();

  // --- Reloj interpolado para el karaoke ---
  late final Ticker _ticker;
  Duration _lastPos = Duration.zero;
  final Stopwatch _sinceLastPos = Stopwatch();
  bool _advancing = false;
  final ValueNotifier<double> _lineProgress = ValueNotifier(0);
  final ValueNotifier<double> _introProgress = ValueNotifier(0);

  /// Pausa larga después de la línea actual (el cantante ya terminó y la
  /// siguiente tarda): se muestran los tres puntitos, como en Apple Music.
  bool _inGap = false;
  final ValueNotifier<double> _gapProgress = ValueNotifier(0);
  int _gapIndex = -2;
  ({Duration start, Duration end})? _gap;

  /// Posición actual (con desfase), actualizada en cada cuadro. Solo la
  /// escucha el pintor de la línea actual, así no se reconstruye nada más.
  final ValueNotifier<Duration> _now = ValueNotifier(Duration.zero);

  bool _autoFollow = true;

  // Buscador dentro de la letra.
  bool _searching = false;
  final TextEditingController _searchController = TextEditingController();
  List<int> _matches = [];
  int _matchCursor = -1;

  // Cómo se muestra cada línea (voz principal / coros con sus tiempos).
  // Se calcula una vez por letra, no en cada reconstrucción.
  List<LinePresentation?> _presentations = [];
  bool _presentationsSplit = true;

  bool get _translationActive =>
      widget.showTranslation && (widget.translatedLines?.isNotEmpty ?? false);

  bool get _hasIntro =>
      widget.lines.isNotEmpty && widget.lines.first.timestamp > const Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listen();
    SettingsService.splitBackgroundVocals.addListener(_onSplitChanged);
    final q = widget.initialSearchQuery;
    if (q != null && q.trim().isNotEmpty && widget.lines.isNotEmpty) {
      _searching = true;
      _searchController.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onSearchChanged(q);
      });
    }
  }

  void _onSplitChanged() {
    if (mounted) setState(() => _presentations = []);
  }

  void _ensureItemKeys() {
    if (_itemKeys.length != widget.lines.length) {
      _itemKeys = List.generate(widget.lines.length, (_) => GlobalKey());
    }
    final split = SettingsService.splitBackgroundVocals.value;
    if (_presentations.length != widget.lines.length || _presentationsSplit != split) {
      _presentations = List.filled(widget.lines.length, null);
      _presentationsSplit = split;
    }
  }

  LinePresentation _presentationFor(int index) {
    return _presentations[index] ??= presentLine(
      widget.lines[index],
      estimatedEnd: widget.lines[index].timestamp + _fillDurationFor(index),
      splitBackground: _presentationsSplit,
    );
  }

  void _listen() {
    _sub = widget.position.listen(_onPosition);
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines != widget.lines) {
      _presentations = [];
      _gapIndex = -2;
    }
    if (oldWidget.position != widget.position || oldWidget.lines != widget.lines) {
      _sub?.cancel();
      _currentIndex = -1;
      _autoFollow = true;
      _lastPos = Duration.zero;
      _advancing = false;
      _listen();
      if (_scrollController.hasClients && oldWidget.lines != widget.lines) {
        _scrollController.jumpTo(0);
      }
    }

    if (oldWidget.lines != widget.lines && _searching) {
      _searching = false;
      _searchController.clear();
      _matches = [];
      _matchCursor = -1;
    }

    // Cambia el alto de las líneas (traducción on/off) o el desfase:
    // reubicamos sin animación para que la línea actual siga en su lugar.
    final oldTranslationActive =
        oldWidget.showTranslation && (oldWidget.translatedLines?.isNotEmpty ?? false);
    if (oldTranslationActive != _translationActive ||
        oldWidget.romanizedLines != widget.romanizedLines ||
        oldWidget.focusMode != widget.focusMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent(animate: false));
    }
    if (oldWidget.offset != widget.offset) {
      _recomputeIndex(_lastPos);
    }
  }

  void _onPosition(Duration pos) {
    if (!mounted) return;
    _advancing = pos > _lastPos && (pos - _lastPos) < const Duration(seconds: 2);
    _lastPos = pos;
    _sinceLastPos
      ..reset()
      ..start();
    _recomputeIndex(pos);
  }

  Duration get _effectiveNow {
    var pos = _lastPos;
    if (_advancing) {
      // Interpolamos entre emisiones, pero sin pasarnos mucho por si se
      // pausó (cuando se pausa dejan de llegar posiciones).
      final extra = math.min(_sinceLastPos.elapsedMilliseconds, 350);
      pos += Duration(milliseconds: extra);
    }
    return pos + widget.offset;
  }

  /// La línea nueva se marca un toque antes de que empiece: el cambio de
  /// línea (resaltado + desplazamiento) tarda en verse, y así queda a
  /// tiempo con la voz en vez de llegar detrás.
  static const _lineLead = Duration(milliseconds: 120);

  void _recomputeIndex(Duration rawPos) => _updateIndex(rawPos + widget.offset);

  /// [pos] ya incluye el desfase.
  void _updateIndex(Duration pos) {
    if (widget.lines.isEmpty) return;
    final at = pos + _lineLead;
    final newIndex = widget.lines.lastIndexWhere((l) => l.timestamp <= at);
    if (newIndex != _currentIndex) {
      setState(() {
        _currentIndex = newIndex;
        _inGap = false;
      });
      if (_autoFollow) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
      }
    }
  }

  /// Cuánto "dura" cantar una línea: hasta la siguiente, pero sin estirar
  /// el relleno durante silencios largos.
  Duration _fillDurationFor(int index) {
    final line = widget.lines[index];
    final next = index + 1 < widget.lines.length
        ? widget.lines[index + 1].timestamp
        : line.timestamp + const Duration(seconds: 5);
    final gap = next - line.timestamp;
    if (_isInterlude(line.text)) return gap;
    if (line.end != null && line.end! > line.timestamp) return line.end! - line.timestamp;
    final estimate = Duration(milliseconds: 700 + line.text.length * 85);
    return gap < estimate ? gap : estimate;
  }

  /// Si después de la línea [index] hay una pausa larga, desde cuándo
  /// hasta cuándo mostrar los puntitos. Con tiempos reales (fin de línea o
  /// por palabra) alcanza con una pausa corta; con tiempos estimados hace
  /// falta una bien larga, para no tapar una nota sostenida.
  ({Duration start, Duration end})? _gapAfter(int index) {
    if (index < 0 || index + 1 >= widget.lines.length) return null;
    final line = widget.lines[index];
    final next = widget.lines[index + 1];
    if (_isInterlude(line.text) || _isInterlude(next.text)) return null;
    final pres = _presentationFor(index);
    final sungUntil = [pres.main?.end, pres.background?.end]
        .whereType<Duration>()
        .fold(line.timestamp, (a, b) => b > a ? b : a);
    final exact = line.end != null || line.hasWordSync;
    final pause = next.timestamp - sungUntil;
    if (pause < (exact ? const Duration(milliseconds: 3500) : const Duration(seconds: 7))) {
      return null;
    }
    final start = sungUntil + (exact ? const Duration(milliseconds: 500) : const Duration(seconds: 2));
    return (start: start, end: next.timestamp);
  }

  void _updateGap(Duration now) {
    if (_gapIndex != _currentIndex) {
      _gapIndex = _currentIndex;
      _gap = _gapAfter(_currentIndex);
    }
    final gap = _gap;
    final inGap = gap != null && now >= gap.start && now < gap.end;
    if (inGap) {
      final total = (gap.end - gap.start).inMilliseconds;
      final p = ((now - gap.start).inMilliseconds / total).clamp(0.0, 1.0);
      if ((p - _gapProgress.value).abs() > 0.002) _gapProgress.value = p;
    }
    if (inGap != _inGap) setState(() => _inGap = inGap);
  }

  void _onTick(Duration _) {
    if (widget.lines.isEmpty) return;
    final now = _effectiveNow;
    _now.value = now;
    _ensureItemKeys();
    // En cada cuadro (no solo cuando llega una posición, cada 150 ms): la
    // línea cambia justo a tiempo.
    if (_advancing) _updateIndex(now);
    _updateGap(now);
    if (_currentIndex >= 0 && _currentIndex < widget.lines.length) {
      final start = widget.lines[_currentIndex].timestamp;
      final total = _fillDurationFor(_currentIndex).inMilliseconds;
      final p = total <= 0 ? 1.0 : ((now - start).inMilliseconds / total).clamp(0.0, 1.0);
      if ((p - _lineProgress.value).abs() > 0.002) _lineProgress.value = p;
    }
    if (_hasIntro && _currentIndex < 0) {
      final total = widget.lines.first.timestamp.inMilliseconds;
      final p = (now.inMilliseconds / total).clamp(0.0, 1.0);
      if ((p - _introProgress.value).abs() > 0.002) _introProgress.value = p;
    }
  }

  void _scrollToCurrent({bool animate = true}) {
    if (!mounted || !_scrollController.hasClients) return;
    final ctx = _currentIndex >= 0 && _currentIndex < _itemKeys.length
        ? _itemKeys[_currentIndex].currentContext
        : _introKey.currentContext;
    if (ctx == null) {
      if (_currentIndex < 0) {
        animate
            ? _scrollController.animateTo(0,
                duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic)
            : _scrollController.jumpTo(0);
      }
      return;
    }
    Scrollable.ensureVisible(
      ctx,
      alignment: _anchor,
      duration: animate ? const Duration(milliseconds: 550) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  void _resumeAutoFollow() {
    setState(() => _autoFollow = true);
    _scrollToCurrent();
  }

  void _onLineTap(int index) {
    final onSeek = widget.onSeek;
    if (onSeek == null) return;
    HapticFeedback.selectionClick();
    final target = widget.lines[index].timestamp - widget.offset;
    onSeek(target < Duration.zero ? Duration.zero : target);
    setState(() => _autoFollow = true);
  }

  void _onLineLongPress(int index) {
    HapticFeedback.mediumImpact();
    showLyricShareSheet(
      context,
      lines: widget.lines.map((l) => l.text).toList(),
      initialIndex: index,
      song: widget.song,
      artworkBytes: widget.artworkBytes,
    );
  }

  // ---------------- Búsqueda dentro de la letra ----------------

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _matches = [];
        _matchCursor = -1;
      }
    });
  }

  void _onSearchChanged(String query) {
    final q = normalizeForSearch(query);
    if (q.isEmpty) {
      setState(() {
        _matches = [];
        _matchCursor = -1;
      });
      return;
    }
    final matches = <int>[
      for (var i = 0; i < widget.lines.length; i++)
        if (normalizeForSearch(widget.lines[i].text).contains(q)) i,
    ];
    setState(() {
      _matches = matches;
      _matchCursor = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) _jumpToMatch(0);
  }

  void _jumpToMatch(int cursor) {
    if (cursor < 0 || cursor >= _matches.length) return;
    setState(() {
      _matchCursor = cursor;
      _autoFollow = false;
    });
    final ctx = _itemKeys[_matches[cursor]].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: _anchor,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    _jumpToMatch((_matchCursor + 1) % _matches.length);
  }

  void _prevMatch() {
    if (_matches.isEmpty) return;
    _jumpToMatch((_matchCursor - 1 + _matches.length) % _matches.length);
  }

  @override
  void dispose() {
    SettingsService.splitBackgroundVocals.removeListener(_onSplitChanged);
    _ticker.dispose();
    _sub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _lineProgress.dispose();
    _introProgress.dispose();
    _gapProgress.dispose();
    _now.dispose();
    super.dispose();
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SettingsService.fontScale,
      builder: (context, scale, _) {
        if (widget.lines.isEmpty) return _buildPlain(scale);
        _ensureItemKeys();
        if (widget.focusMode) return _buildFocus(scale);
        return _buildSynced(scale);
      },
    );
  }

  Widget _buildPlain(double scale) {
    final text = widget.plainLyricsFallback.trim();
    if (text.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Letra no disponible.',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 120),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Letra sin sincronizar',
                  style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                text,
                style: TextStyle(
                  fontSize: 21 * scale,
                  height: 1.55,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// En pantallas anchas la letra crece con el espacio (como en Música de
  /// la Mac); en el teléfono queda igual.
  static double _widthScale(double width) => (width / 560).clamp(1.0, 1.4);

  Widget _buildSynced(double scale) {
    return LayoutBuilder(builder: (context, outer) {
      final fontSize = 27.0 * scale * _widthScale(outer.maxWidth) * widget.sizeBoost;
      // Renglones de un largo cómodo: los coros (a la derecha) quedan cerca
      // de la línea principal en vez de irse al borde de la ventana.
      final maxLineWidth = math.max(fontSize * 20, 360.0);
      // Sin barra de desplazamiento (en la Mac aparece sola y ensucia).
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: _buildSyncedSized(fontSize, maxLineWidth),
      );
    });
  }

  Widget _buildSyncedSized(double fontSize, double maxLineWidth) {
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final h = constraints.maxHeight;
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null &&
                  _autoFollow) {
                setState(() => _autoFollow = false);
              }
              return false;
            },
            child: ShaderMask(
              // Difumina arriba y abajo para que la letra "entre" y "salga"
              // suave, en vez de cortarse de golpe contra el borde.
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.08, 0.86, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.only(top: h * _anchor, bottom: h * (1 - _anchor)),
                child: ValueListenableBuilder<bool>(
                  valueListenable: SettingsService.blurDistantLines,
                  builder: (context, blur, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxLineWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_hasIntro)
                            KeyedSubtree(
                              key: _introKey,
                              child: _InterludeDots(
                                active: _currentIndex < 0,
                                progress: _introProgress,
                                size: fontSize,
                              ),
                            ),
                          for (var i = 0; i < widget.lines.length; i++)
                            _buildLine(i, fontSize, blur: blur),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
        _buildFollowButton(),
        if (widget.showSearchButton && !_searching)
          Positioned(
            top: 4,
            right: 12,
            child: Material(
              color: Colors.black26,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Buscar en la letra',
                icon: const Icon(Icons.search_rounded, color: Colors.white70),
                onPressed: _toggleSearch,
              ),
            ),
          ),
        if (_searching) _buildSearchBar(),
      ],
    );
  }

  /// Cuánto se desenfoca una línea según qué tan lejos está de la actual.
  /// Mientras el usuario scrollea a mano o busca, nada se desenfoca (para
  /// poder leer todo), igual que en Apple Music.
  double _blurFor(int index, bool blurEnabled) {
    if (!blurEnabled || !_autoFollow || _searching || _currentIndex < 0) return 0;
    final distance = (index - _currentIndex).abs();
    if (distance == 0) return 0;
    return math.min(0.5 + distance * 0.7, 3.2);
  }

  Widget _buildLine(int index, double fontSize, {required bool blur}) {
    final line = widget.lines[index];
    // En una pausa larga la línea que terminó se apaga y se ven los puntitos.
    final pausedAfter = index == _currentIndex && _inGap;
    final isCurrent = index == _currentIndex && !_inGap;
    final distance = (index - _currentIndex).abs();
    final isMatch = _matches.contains(index);
    final isActiveMatch =
        _matchCursor >= 0 && _matches.isNotEmpty && _matches[_matchCursor] == index;
    final accent = Theme.of(context).colorScheme.primary;

    if (_isInterlude(line.text)) {
      return KeyedSubtree(
        key: _itemKeys[index],
        child: _InterludeDots(
          active: isCurrent,
          progress: _lineProgress,
          size: fontSize,
          onTap: widget.onSeek == null ? null : () => _onLineTap(index),
        ),
      );
    }

    final translation = _translationActive && index < widget.translatedLines!.length
        ? widget.translatedLines![index]
        : '';
    final romanized = SettingsService.showRomanization.value &&
            widget.romanizedLines != null &&
            index < widget.romanizedLines!.length
        ? widget.romanizedLines![index]
        : '';

    // Las líneas lejanas a la actual se apagan de a poco, como en Apple Music.
    final double opacity = isCurrent
        ? 1.0
        : (_currentIndex < 0 ? 0.45 : (distance <= 1 ? 0.42 : (distance <= 3 ? 0.32 : 0.24)));

    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      height: 1.22,
      letterSpacing: -0.3,
      color: Colors.white,
    );

    final content = _buildLineContent(
      index,
      baseStyle: baseStyle,
      isCurrent: isCurrent,
      romanized: romanized,
      translation: translation,
    );

    final hovered = _hoveredLine == index && widget.onSeek != null;
    final lineWidget = MouseRegion(
      cursor: widget.onSeek != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hoveredLine = index),
      onExit: (_) {
        if (_hoveredLine == index) setState(() => _hoveredLine = null);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onLineTap(index),
        onLongPress: () => _onLineLongPress(index),
        // En la compu, clic derecho = lo mismo que mantener apretado.
        onSecondaryTap: () => _onLineLongPress(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isMatch
                ? accent.withValues(alpha: isActiveMatch ? 0.25 : 0.12)
                : (hovered ? Colors.white.withValues(alpha: 0.07) : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _Blur(
            // Al pasar el mouse la línea se lee entera, aunque esté lejos.
            sigma: hovered ? 0 : _blurFor(index, blur),
            child: AnimatedScale(
              scale: isCurrent ? 1.0 : 0.96,
              alignment: Alignment.centerLeft,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: hovered ? math.max(opacity, 0.7) : opacity,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOut,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
    return Column(
      key: _itemKeys[index],
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        lineWidget,
        AnimatedSize(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: pausedAfter
              ? _InterludeDots(active: true, progress: _gapProgress, size: fontSize)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// Voz principal + coros (más chicos, a la derecha) + pronunciación +
  /// traducción de una línea.
  Widget _buildLineContent(
    int index, {
    required TextStyle baseStyle,
    required bool isCurrent,
    String romanized = '',
    String translation = '',
    TextAlign align = TextAlign.left,
  }) {
    final pres = _presentationFor(index);
    final bgStyle = baseStyle.copyWith(
      fontSize: (baseStyle.fontSize ?? 27) * 0.62,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );

    Widget part(VocalPart p, TextStyle style, TextAlign textAlign) {
      if (!isCurrent) return Text(p.text, style: style, textAlign: textAlign);
      return ValueListenableBuilder<bool>(
        valueListenable: SettingsService.karaokeFill,
        builder: (context, karaoke, _) => karaoke
            ? _KaraokeText(part: p, style: style, now: _now, textAlign: textAlign)
            : Text(p.text, style: style, textAlign: textAlign),
      );
    }

    final secondaryAlign = align == TextAlign.center ? TextAlign.center : TextAlign.left;
    return Column(
      crossAxisAlignment:
          align == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
      children: [
        if (pres.main != null) part(pres.main!, baseStyle, align),
        if (pres.background != null) ...[
          if (pres.main != null) const SizedBox(height: 2),
          Opacity(
            opacity: 0.8,
            child: part(
              pres.background!,
              bgStyle,
              align == TextAlign.center ? TextAlign.center : TextAlign.right,
            ),
          ),
        ],
        if (romanized.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            romanized,
            textAlign: secondaryAlign,
            style: TextStyle(
              fontSize: (baseStyle.fontSize ?? 27) * 0.5,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ],
        if (translation.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            translation,
            textAlign: secondaryAlign,
            style: TextStyle(
              fontSize: (baseStyle.fontSize ?? 27) * 0.58,
              fontWeight: FontWeight.w500,
              height: 1.25,
              color: Colors.white.withValues(alpha: isCurrent ? 0.75 : 0.9),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------- Modo "solo la línea actual" ----------------

  Widget _buildFocus(double scale) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth - 48;
      final height = constraints.maxHeight;
      final index = _currentIndex;
      final next = index + 1 < widget.lines.length ? widget.lines[index + 1] : null;
      final translation = _translationActive && index >= 0 && index < widget.translatedLines!.length
          ? widget.translatedLines![index]
          : '';

      Widget current;
      if (index < 0 || _inGap || _isInterlude(widget.lines[index].text)) {
        current = _InterludeDots(
          key: ValueKey('dots$index$_inGap'),
          active: true,
          progress: index < 0 ? _introProgress : (_inGap ? _gapProgress : _lineProgress),
          size: math.min(height * 0.12, 90),
          center: true,
        );
      } else {
        final text = widget.lines[index].text;
        final size = fitFocusFontSize(
          text,
          maxWidth: width,
          maxHeight: height * 0.55,
          maxSize: math.min(height * 0.16, 140) * scale,
          textScaler: MediaQuery.textScalerOf(context),
        );
        current = KeyedSubtree(
          key: ValueKey('line$index'),
          child: _buildLineContent(
            index,
            baseStyle: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w800,
              height: 1.15,
              color: Colors.white,
            ),
            isCurrent: true,
            translation: translation,
            align: TextAlign.center,
          ),
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: (widget.onSeek != null && index >= 0) ? () => _onLineTap(index) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(anim),
                    child: child,
                  ),
                ),
                child: current,
              ),
              if (next != null && !_isInterlude(next.text)) ...[
                SizedBox(height: height * 0.06),
                Text(
                  next.text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: math.min(height * 0.055, 40) * scale,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }

  Widget _buildFollowButton() {
    final accent = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      ignoring: _autoFollow,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        offset: _autoFollow ? const Offset(0, 2) : Offset.zero,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _autoFollow ? 0 : 1,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Material(
              color: accent,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: _resumeAutoFollow,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.my_location_rounded, size: 16, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Seguir la canción',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Positioned(
      top: 4,
      left: 12,
      right: 12,
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, color: Colors.white54, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  autofocus: widget.initialSearchQuery == null,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: const InputDecoration(
                    hintText: 'Buscar en la letra...',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    filled: false,
                    isDense: true,
                  ),
                ),
              ),
              if (_matches.isNotEmpty)
                Text(
                  '${_matchCursor + 1}/${_matches.length}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white70),
                onPressed: _matches.isEmpty ? null : _prevMatch,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
                onPressed: _matches.isEmpty ? null : _nextMatch,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                onPressed: _toggleSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desenfoque animado: pasa suave de nítido a borroso cuando cambia la
/// línea actual. Con desenfoque 0 no agrega ningún filtro (no cuesta nada).
class _Blur extends StatelessWidget {
  final double sigma;
  final Widget child;

  const _Blur({required this.sigma, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: sigma),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      child: child,
      builder: (context, s, child) => s < 0.05
          ? child!
          : ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal),
              child: child,
            ),
    );
  }
}

/// Texto con relleno tipo karaoke, como Apple Music: cada palabra se va
/// iluminando de izquierda a derecha con un borde suave mientras se canta,
/// sube un poquito al cantarse y, si es una nota larga, brilla y se agranda
/// apenas. Sigue los tiempos de cada palabra (exactos si la letra los trae,
/// estimados si no) y respeta los saltos de renglón. Solo se repinta (no se
/// reconstruye) cuando avanza [now].
class _KaraokeText extends StatelessWidget {
  final VocalPart part;
  final TextStyle style;
  final ValueListenable<Duration> now;
  final TextAlign textAlign;

  const _KaraokeText({
    required this.part,
    required this.style,
    required this.now,
    this.textAlign = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final painter = _KaraokePainter(
        part: part,
        // La misma fuente que un Text común (la del tema).
        style: DefaultTextStyle.of(context).style.merge(style),
        maxWidth: constraints.maxWidth,
        now: now,
        textAlign: textAlign,
        textScaler: MediaQuery.textScalerOf(context),
      );
      return CustomPaint(
        size: Size(constraints.maxWidth, painter.height),
        painter: painter,
      );
    });
  }
}

/// Una palabra ya ubicada en pantalla: sus cajas (una por renglón, casi
/// siempre una sola) y cuándo se canta.
class _PlacedWord {
  final List<Rect> boxes;
  final double width;
  final Duration start;
  final Duration end;
  final String text;
  final Offset origin;

  _PlacedWord(this.boxes, this.start, this.end, this.text)
      : width = boxes.fold(0.0, (w, b) => w + b.width),
        origin = boxes.first.topLeft;

  bool get isLong => end - start >= const Duration(milliseconds: 1000);

  double progress(Duration now) {
    if (now <= start) return 0;
    if (now >= end) return 1;
    return (now - start).inMicroseconds / (end - start).inMicroseconds;
  }
}

class _KaraokePainter extends CustomPainter {
  final VocalPart part;
  final ValueListenable<Duration> now;
  final TextStyle style;
  final TextScaler textScaler;
  late final TextPainter _bright;
  late final TextPainter _dim;
  late final List<_PlacedWord> _words;
  final Map<int, TextPainter> _glows = {};

  _KaraokePainter({
    required this.part,
    required this.style,
    required double maxWidth,
    required this.now,
    required TextAlign textAlign,
    required this.textScaler,
  }) : super(repaint: now) {
    TextPainter make(TextStyle s) => TextPainter(
          text: TextSpan(text: part.text, style: s),
          textDirection: TextDirection.ltr,
          textAlign: textAlign,
          textScaler: textScaler,
        )..layout(minWidth: maxWidth, maxWidth: maxWidth);
    _bright = make(style);
    _dim = make(style.copyWith(color: (style.color ?? Colors.white).withValues(alpha: 0.36)));
    _words = [];
    for (final seg in part.segments) {
      // Sin los espacios del final: el relleno termina con la última letra.
      var to = seg.to;
      while (to > seg.from && part.text[to - 1].trim().isEmpty) {
        to--;
      }
      if (to <= seg.from) continue;
      final boxes = _bright
          .getBoxesForSelection(TextSelection(baseOffset: seg.from, extentOffset: to))
          .map((b) => b.toRect())
          .where((r) => r.width > 0)
          .toList();
      if (boxes.isEmpty) continue;
      _words.add(_PlacedWord(boxes, seg.start, seg.end, part.text.substring(seg.from, to)));
    }
  }

  double get _fontSize => textScaler.scale(style.fontSize ?? 27);

  /// Cuánto sube una palabra ya cantada.
  double get _maxLift => _fontSize * 0.06;

  double get height => _bright.height;

  /// Recorte de una caja corrida [lift] hacia arriba. El primer renglón
  /// tiene margen arriba para los acentos de las mayúsculas.
  Rect _clip(Rect box, double lift) =>
      Rect.fromLTRB(box.left, box.top - lift - (box.top < 1 ? _fontSize * 0.3 : 0), box.right,
          box.bottom - lift);

  @override
  void paint(Canvas canvas, Size size) {
    if (_words.isEmpty) {
      _dim.paint(canvas, Offset.zero);
      return;
    }
    final t = now.value;
    final done = Path();
    final pending = Path();
    final active = <(_PlacedWord, double)>[];
    for (final w in _words) {
      final p = w.progress(t);
      if (p >= 1) {
        for (final b in w.boxes) {
          done.addRect(_clip(b, _maxLift));
        }
      } else if (p <= 0) {
        for (final b in w.boxes) {
          pending.addRect(_clip(b, 0));
        }
      } else {
        active.add((w, p));
      }
    }

    // Lo que falta cantar: tenue y en su lugar.
    canvas.save();
    canvas.clipPath(pending);
    _dim.paint(canvas, Offset.zero);
    canvas.restore();

    // Lo ya cantado: iluminado y un poquito más arriba.
    canvas.save();
    canvas.clipPath(done);
    _bright.paint(canvas, Offset(0, -_maxLift));
    canvas.restore();

    for (final (w, p) in active) {
      _paintActive(canvas, w, p);
    }
  }

  /// La palabra que se está cantando: se ilumina con un borde difuminado
  /// que avanza, va subiendo y, si es larga, brilla.
  void _paintActive(Canvas canvas, _PlacedWord w, double p) {
    final eased = Curves.easeOutCubic.transform(p);
    final lift = _maxLift * eased;
    final glow = w.isLong ? math.sin(p * math.pi) : 0.0;
    final feather = _fontSize * 0.5;
    // Del borde izquierdo (todo tenue) al derecho (todo iluminado), contando
    // los renglones si la palabra quedó partida.
    final edge = -feather / 2 + (w.width + feather) * p;
    var before = 0.0;

    canvas.save();
    if (glow > 0) {
      // Las notas largas se agrandan apenas, desde el centro de la palabra.
      final c = w.boxes.first.center;
      canvas.translate(c.dx, c.dy);
      canvas.scale(1 + 0.035 * glow);
      canvas.translate(-c.dx, -c.dy);
      _paintGlow(canvas, w, glow, lift);
    }
    for (final b in w.boxes) {
      final clip = _clip(b, lift);
      canvas.save();
      canvas.clipRect(clip);
      _dim.paint(canvas, Offset(0, -lift));
      final local = edge - before;
      if (local > -feather / 2) {
        canvas.saveLayer(clip, Paint());
        _bright.paint(canvas, Offset(0, -lift));
        final x = b.left + local;
        canvas.drawRect(
          clip,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              Offset(x - feather / 2, 0),
              Offset(x + feather / 2, 0),
              const [Colors.white, Color(0x00FFFFFF)],
            ),
        );
        canvas.restore();
      }
      canvas.restore();
      before += b.width;
    }
    canvas.restore();
  }

  /// Un halo suave detrás de la palabra (solo la palabra, para que no se
  /// prendan las vecinas).
  void _paintGlow(Canvas canvas, _PlacedWord w, double intensity, double lift) {
    if (w.boxes.length != 1) return;
    final index = _words.indexOf(w);
    final glowPainter = _glows[index] ??= TextPainter(
      text: TextSpan(
        text: w.text,
        style: style.copyWith(
          color: Colors.white.withValues(alpha: 0.0),
          shadows: [
            Shadow(color: Colors.white.withValues(alpha: 0.9), blurRadius: _fontSize * 0.35),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    canvas.saveLayer(
      w.boxes.first.inflate(_fontSize),
      Paint()..color = Colors.white.withValues(alpha: 0.55 * intensity),
    );
    glowPainter.paint(canvas, w.origin.translate(0, -lift));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KaraokePainter old) =>
      old.part != part || old.now != now || old._bright.text != _bright.text;
}

/// Los tres puntitos de los instrumentales: cuando están activos "respiran"
/// y se van llenando a medida que se acerca la siguiente línea.
class _InterludeDots extends StatelessWidget {
  final bool active;
  final ValueListenable<double> progress;
  final double size;
  final VoidCallback? onTap;
  final bool center;

  const _InterludeDots({
    super.key,
    required this.active,
    required this.progress,
    required this.size,
    this.onTap,
    this.center = false,
  });

  @override
  Widget build(BuildContext context) {
    final dot = size * 0.36;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: active ? 18 : 4),
          child: active
              ? ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (context, p, _) {
                    // Respiración suave: escala entre 0.9 y 1.1.
                    final breathe = 1 + 0.1 * math.sin(p * math.pi * 6);
                    return Transform.scale(
                      scale: breathe,
                      alignment: center ? Alignment.center : Alignment.centerLeft,
                      child: Row(
                        mainAxisAlignment:
                            center ? MainAxisAlignment.center : MainAxisAlignment.start,
                        children: [
                          for (var i = 0; i < 3; i++) ...[
                            Container(
                              width: dot,
                              height: dot,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(
                                  alpha: 0.3 + 0.7 * ((p * 3 - i).clamp(0.0, 1.0)),
                                ),
                              ),
                            ),
                            if (i < 2 || !center) SizedBox(width: dot * 0.7),
                          ],
                        ],
                      ),
                    );
                  },
                )
              : const SizedBox(height: 4, width: double.infinity),
        ),
      ),
    );
  }
}
