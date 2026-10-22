import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/song.dart';
import '../theme/app_theme.dart';
import 'desktop.dart';

/// Hoja para compartir líneas de una letra, estilo "compartir letra" de
/// Spotify: eliges una o varias líneas seguidas y las copias, las mandas
/// como texto, o generas una tarjeta-imagen con la carátula de fondo.
Future<void> showLyricShareSheet(
  BuildContext context, {
  required List<String> lines,
  required int initialIndex,
  Song? song,
  Uint8List? artworkBytes,
}) {
  return showAdaptiveSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LyricShareSheet(
      lines: lines,
      initialIndex: initialIndex,
      song: song,
      artworkBytes: artworkBytes,
    ),
  );
}

class _LyricShareSheet extends StatefulWidget {
  final List<String> lines;
  final int initialIndex;
  final Song? song;
  final Uint8List? artworkBytes;

  const _LyricShareSheet({
    required this.lines,
    required this.initialIndex,
    this.song,
    this.artworkBytes,
  });

  @override
  State<_LyricShareSheet> createState() => _LyricShareSheetState();
}

class _LyricShareSheetState extends State<_LyricShareSheet> {
  static const _maxLines = 6;
  late int _start = widget.initialIndex;
  late int _end = widget.initialIndex; // inclusivo

  List<String> get _selected => widget.lines
      .sublist(_start, _end + 1)
      .where((l) => l.trim().isNotEmpty)
      .toList();

  String get _attribution {
    final s = widget.song;
    if (s == null) return '';
    return '${s.title} — ${s.artist}';
  }

  String get _shareText {
    final body = _selected.join('\n');
    return _attribution.isEmpty ? body : '"$body"\n\n$_attribution';
  }

  void _toggle(int index) {
    setState(() {
      if (index < _start) {
        if (_end - index < _maxLines) _start = index;
      } else if (index > _end) {
        if (index - _start < _maxLines) _end = index;
      } else if (index == _start && _start < _end) {
        _start++;
      } else if (index == _end && _end > _start) {
        _end--;
      }
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copiado al portapapeles.')),
    );
  }

  Future<void> _shareAsText() async {
    await SharePlus.instance.share(ShareParams(text: _shareText));
  }

  Future<void> _shareAsCard() async {
    final navigator = Navigator.of(context);
    await showDialog(
      context: context,
      builder: (_) => _CardPreviewDialog(
        lines: _selected,
        song: widget.song,
        artworkBytes: widget.artworkBytes,
      ),
    );
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final from = (widget.initialIndex - 6).clamp(0, widget.lines.length);
    final to = (widget.initialIndex + 10).clamp(0, widget.lines.length);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            const SheetHandle(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text(
                'Elige las líneas (hasta 6 seguidas)',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = from; i < to; i++)
                    if (widget.lines[i].trim().isNotEmpty)
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _toggle(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: Row(
                            children: [
                              Icon(
                                i >= _start && i <= _end
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                size: 20,
                                color: i >= _start && i <= _end
                                    ? Theme.of(context).colorScheme.primary
                                    : AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  widget.lines[i],
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: i >= _start && i <= _end
                                        ? Colors.white
                                        : Colors.white54,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _action(Icons.copy_rounded, 'Copiar', _copy),
                  _action(Icons.ios_share_rounded, 'Texto', _shareAsText),
                  _action(Icons.image_rounded, 'Tarjeta', _shareAsCard),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Vista previa de la tarjeta + botón para compartirla como imagen.
class _CardPreviewDialog extends StatefulWidget {
  final List<String> lines;
  final Song? song;
  final Uint8List? artworkBytes;

  const _CardPreviewDialog({required this.lines, this.song, this.artworkBytes});

  @override
  State<_CardPreviewDialog> createState() => _CardPreviewDialogState();
}

class _CardPreviewDialogState extends State<_CardPreviewDialog> {
  final _boundaryKey = GlobalKey();
  bool _sharing = false;
  int _palette = 0;

  static const _palettes = <List<Color>>[
    [Color(0xFFFC3C44), Color(0xFF6A0DAD)],
    [Color(0xFF1DB954), Color(0xFF0B3D2E)],
    [Color(0xFF2B5876), Color(0xFF4E4376)],
    [Color(0xFFF7971E), Color(0xFFD9480F)],
    [Color(0xFF232526), Color(0xFF414345)],
  ];

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/letra_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      final song = widget.song;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: song == null ? null : '${song.title} — ${song.artist}',
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo generar la imagen: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final colors = _palettes[_palette];
    final art = widget.artworkBytes;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            key: _boundaryKey,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 320,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: colors,
                  ),
                ),
                child: Stack(
                  children: [
                    if (art != null && _palette == 0)
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                          child: Image.memory(art, fit: BoxFit.cover),
                        ),
                      ),
                    if (art != null && _palette == 0)
                      Positioned.fill(child: Container(color: Colors.black38)),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (song != null)
                            Row(
                              children: [
                                if (art != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(art, width: 44, height: 44, fit: BoxFit.cover),
                                  ),
                                if (art != null) const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        song.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        song.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 22),
                          Text(
                            widget.lines.join('\n'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Row(
                            children: [
                              Icon(Icons.graphic_eq_rounded, color: Colors.white70, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'Letras',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _palettes.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _palette = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: _palettes[i]),
                      border: Border.all(
                        color: i == _palette ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _sharing ? null : _share,
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.ios_share_rounded),
            label: const Text('Compartir'),
          ),
        ],
      ),
    );
  }
}
