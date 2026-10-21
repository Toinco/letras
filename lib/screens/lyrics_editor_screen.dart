import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/lyric_line.dart';
import '../models/lyrics_result.dart';
import '../models/song.dart';
import '../services/lrclib_publisher.dart';
import '../theme/app_theme.dart';

class _EditLine {
  String text;
  Duration? time;

  _EditLine(this.text, [this.time]);
}

/// Editor para corregir una letra y sincronizarla a mano: primero se
/// escribe/corrige el texto, después se va tocando "Marcar" justo cuando
/// empieza cada línea mientras suena la canción. Al guardar, ofrece
/// subirla a LRCLIB para que le sirva a todo el mundo.
///
/// Si [livePosition] viene de lo que suena en el teléfono, se usa esa
/// posición; si no, el editor tiene su propio reloj con play/pausa (para
/// sincronizar mirando un video, por ejemplo).
class LyricsEditorScreen extends StatefulWidget {
  final Song song;
  final LyricsResult? initial;
  final Stream<Duration>? livePosition;
  final ValueChanged<Duration>? onSeek;

  const LyricsEditorScreen({
    super.key,
    required this.song,
    this.initial,
    this.livePosition,
    this.onSeek,
  });

  @override
  State<LyricsEditorScreen> createState() => _LyricsEditorScreenState();
}

class _LyricsEditorScreenState extends State<LyricsEditorScreen> {
  late final TextEditingController _text;
  final _scroll = ScrollController();
  List<_EditLine> _lines = [];
  int _step = 0; // 0 = texto, 1 = sincronizar
  int _cursor = 0;

  // Posición: la de la música real, o un reloj propio.
  StreamSubscription<Duration>? _sub;
  Duration _livePos = Duration.zero;
  final Stopwatch _manualClock = Stopwatch();
  Duration _manualBase = Duration.zero;
  Timer? _repaint;

  bool get _live => widget.livePosition != null;

  Duration get _now => _live ? _livePos : _manualBase + _manualClock.elapsed;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final textLines = initial == null
        ? <String>[]
        : (initial.hasSyncedLyrics
            ? initial.syncedLyrics.map((l) => l.text).toList()
            : initial.plainLyrics.split('\n'));
    _text = TextEditingController(text: textLines.join('\n'));
    if (initial != null && initial.hasSyncedLyrics) {
      _lines = [for (final l in initial.syncedLyrics) _EditLine(l.text, l.timestamp)];
    }
    _sub = widget.livePosition?.listen((p) => _livePos = p);
    _repaint = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _step == 1) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repaint?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Pasa del texto a la lista de líneas, conservando los tiempos de las
  /// líneas que no cambiaron.
  void _goToSync() {
    final texts = _text.text.split('\n').map((l) => l.trim()).toList();
    while (texts.isNotEmpty && texts.last.isEmpty) {
      texts.removeLast();
    }
    if (texts.where((t) => t.isNotEmpty).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero escribe o pega la letra.')),
      );
      return;
    }
    final previous = {for (final l in _lines) l.text: l.time};
    setState(() {
      _lines = [
        // Un renglón vacío es un instrumental (se ve como "♪").
        for (final t in texts) _EditLine(t, previous[t]),
      ];
      _cursor = _lines.indexWhere((l) => l.time == null);
      if (_cursor < 0) _cursor = _lines.length;
      _step = 1;
    });
  }

  void _mark() {
    if (_cursor >= _lines.length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _lines[_cursor].time = _now;
      _cursor++;
    });
    _scrollToCursor();
  }

  void _undo() {
    if (_cursor <= 0) return;
    setState(() {
      _cursor--;
      _lines[_cursor].time = null;
    });
    _scrollToCursor();
  }

  void _nudge(int index, int deltaMs) {
    final t = _lines[index].time;
    if (t == null) return;
    setState(() {
      final ms = (t.inMilliseconds + deltaMs).clamp(0, 1 << 31);
      _lines[index].time = Duration(milliseconds: ms);
    });
  }

  void _scrollToCursor() {
    if (!_scroll.hasClients) return;
    final target = (_cursor - 2).clamp(0, _lines.length) * 56.0;
    _scroll.animateTo(
      target.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _seek(Duration to) {
    final clamped = to < Duration.zero ? Duration.zero : to;
    if (_live) {
      widget.onSeek?.call(clamped);
    } else {
      setState(() {
        _manualBase = clamped;
        _manualClock.reset();
      });
    }
  }

  void _toggleManualClock() {
    setState(() {
      if (_manualClock.isRunning) {
        _manualBase += _manualClock.elapsed;
        _manualClock
          ..stop()
          ..reset();
      } else {
        _manualClock.start();
      }
    });
  }

  String _fmt(Duration d) {
    final cs = (d.inMilliseconds / 10).round();
    return '${cs ~/ 6000}:${((cs % 6000) ~/ 100).toString().padLeft(2, '0')}.'
        '${(cs % 100).toString().padLeft(2, '0')}';
  }

  LyricsResult _buildResult({required bool synced}) {
    final plain = _step == 0
        ? _text.text.trim()
        : _lines.map((l) => l.text).join('\n').trim();
    final lines = synced
        ? ([
            for (final l in _lines) LyricLine(timestamp: l.time!, text: l.text),
          ]..sort((a, b) => a.timestamp.compareTo(b.timestamp)))
        : const <LyricLine>[];
    return LyricsResult(
      song: widget.initial?.song.withIdentityFrom(widget.song) ?? widget.song,
      plainLyrics: plain,
      syncedLyrics: lines,
      source: LyricsSource.manual,
      editedByUser: true,
    );
  }

  Future<void> _save() async {
    final allTimed = _step == 1 && _lines.isNotEmpty && _lines.every((l) => l.time != null);
    if (!allTimed) {
      final plainOk = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Guardar sin sincronizar?'),
          content: Text(_step == 0
              ? 'Todavía no marcaste los tiempos. Se va a guardar como letra sin '
                  'sincronizar (sin animación).'
              : 'Faltan ${_lines.where((l) => l.time == null).length} líneas por marcar. '
                  'Se va a guardar como letra sin sincronizar.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Seguir')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      );
      if (plainOk != true || !mounted) return;
    }
    final result = _buildResult(synced: allTimed);
    if (allTimed) await _offerPublish(result);
    if (mounted) Navigator.of(context).pop(result);
  }

  /// Ofrece subir la letra a LRCLIB (pide álbum y duración, que LRCLIB exige).
  Future<void> _offerPublish(LyricsResult result) async {
    final album = TextEditingController(
      text: widget.song.album ?? widget.initial?.song.album ?? '',
    );
    final duration = TextEditingController(
      text: '${widget.song.durationSeconds ?? widget.initial?.song.durationSeconds ?? ''}',
    );
    final publish = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Subirla a LRCLIB?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Así le aparece sincronizada a cualquiera que use LRCLIB (esta app y '
                'muchas otras). Se publica de forma anónima y no se puede borrar.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(controller: album, decoration: const InputDecoration(labelText: 'Álbum')),
              const SizedBox(height: 8),
              TextField(
                controller: duration,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Duración (segundos)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Solo guardar')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Publicar')),
        ],
      ),
    );
    if (publish != true || !mounted) return;

    final step = ValueNotifier('Preparando...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: step,
                builder: (_, s, __) => Text(s),
              ),
            ),
          ],
        ),
      ),
    );
    String message;
    try {
      await LrclibPublisher().publish(
        result,
        album: album.text,
        durationSeconds: int.tryParse(duration.text.trim()) ?? 0,
        onProgress: (s) => step.value = s,
      );
      message = '¡Publicada en LRCLIB! Gracias por aportar.';
    } catch (e) {
      message = 'No se pudo publicar: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // cierra el diálogo de progreso
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_step == 0 ? 'Corregir letra' : 'Sincronizar'),
        actions: [
          if (_step == 1)
            TextButton(
              onPressed: () => setState(() => _step = 0),
              child: const Text('Texto'),
            ),
          TextButton(onPressed: _save, child: const Text('Guardar')),
        ],
      ),
      body: _step == 0 ? _buildTextStep() : _buildSyncStep(),
    );
  }

  Widget _buildTextStep() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.song.title} — ${widget.song.artist}',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Una línea por renglón. Un renglón vacío marca una parte instrumental.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(hintText: 'Escribe o pega la letra aquí...'),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _goToSync,
            icon: const Icon(Icons.timer_rounded),
            label: const Text('Siguiente: marcar los tiempos'),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncStep() {
    final accent = Theme.of(context).colorScheme.primary;
    final done = _cursor >= _lines.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Text(
                _fmt(_now),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Volver 3 segundos',
                icon: const Icon(Icons.replay_rounded),
                onPressed: (_live && widget.onSeek == null)
                    ? null
                    : () => _seek(_now - const Duration(seconds: 3)),
              ),
              if (!_live)
                IconButton.filled(
                  icon: Icon(_manualClock.isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: _toggleManualClock,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _live
                ? 'Pon la canción desde el principio y toca "Marcar" justo cuando empieza cada línea.'
                : 'Arranca el reloj junto con la canción y toca "Marcar" cuando empieza cada línea.',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: _lines.length,
            itemExtent: 56,
            itemBuilder: (context, i) {
              final l = _lines[i];
              final isCursor = i == _cursor;
              return Material(
                color: isCursor ? accent.withValues(alpha: 0.18) : Colors.transparent,
                child: InkWell(
                  onTap: () => setState(() => _cursor = i),
                  onLongPress: () => setState(() => l.time = null),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 74,
                          child: GestureDetector(
                            onTap: l.time == null
                                ? null
                                : () => _seek(l.time! - const Duration(seconds: 2)),
                            child: Text(
                              l.time == null ? '--:--.--' : _fmt(l.time!),
                              style: TextStyle(
                                color: l.time == null ? Colors.white30 : accent,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            l.text.isEmpty ? '♪' : l.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isCursor ? FontWeight.w700 : FontWeight.w500,
                              color: l.time == null && !isCursor ? Colors.white60 : Colors.white,
                            ),
                          ),
                        ),
                        if (l.time != null) ...[
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '-0.1 s',
                            icon: const Icon(Icons.remove_rounded, size: 18),
                            onPressed: () => _nudge(i, -100),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '+0.1 s',
                            icon: const Icon(Icons.add_rounded, size: 18),
                            onPressed: () => _nudge(i, 100),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _cursor > 0 ? _undo : null,
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Deshacer'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 64,
                    child: ElevatedButton(
                      onPressed: done ? _save : _mark,
                      child: Text(
                        done ? 'Listo: guardar' : 'Marcar línea ${_cursor + 1} de ${_lines.length}',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
