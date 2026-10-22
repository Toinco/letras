import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/stats_service.dart';
import '../theme/app_theme.dart';
import '../providers.dart';
import '../widgets/desktop.dart';

enum _Range { week, month, year, all }

/// Estadísticas de escucha: canciones y artistas más escuchados, y cuántas
/// horas de letras viste.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  late final _stats = ref.read(statsProvider);
  _Range _range = _Range.month;
  ListeningStats? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? get _since {
    final now = DateTime.now();
    return switch (_range) {
      _Range.week => now.subtract(const Duration(days: 7)),
      _Range.month => now.subtract(const Duration(days: 30)),
      _Range.year => now.subtract(const Duration(days: 365)),
      _Range.all => null,
    };
  }

  Future<void> _load() async {
    final data = await _stats.load(since: _since, top: 15);
    if (mounted) setState(() => _data = data);
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar las estadísticas?'),
        content: const Text('Se borra todo el historial de escucha. No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await _stats.clear();
    _load();
  }

  static String formatTime(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final accent = Theme.of(context).colorScheme.primary;
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Estadísticas'),
          actions: [
            IconButton(
              tooltip: 'Borrar estadísticas',
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: _clear,
            ),
          ],
        ),
        body: data == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  SegmentedButton<_Range>(
                    segments: const [
                      ButtonSegment(value: _Range.week, label: Text('7 días')),
                      ButtonSegment(value: _Range.month, label: Text('30 días')),
                      ButtonSegment(value: _Range.year, label: Text('Año')),
                      ButtonSegment(value: _Range.all, label: Text('Todo')),
                    ],
                    selected: {_range},
                    onSelectionChanged: (s) {
                      setState(() => _range = s.first);
                      _load();
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _Tile(value: formatTime(data.lyricsTime), label: 'de letras vistas'),
                      const SizedBox(width: 10),
                      _Tile(value: '${data.totalPlays}', label: 'reproducciones'),
                      const SizedBox(width: 10),
                      _Tile(value: '${data.distinctSongs}', label: 'canciones'),
                    ],
                  ),
                  if (data.totalPlays == 0)
                    const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Text(
                        'Todavía no hay nada en este período. Las canciones que suenan con '
                        'letra en "Reproduciendo" se cuentan solas.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  if (data.topSongs.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const _Header('CANCIONES MÁS ESCUCHADAS'),
                    for (var i = 0; i < data.topSongs.length; i++)
                      _RankRow(
                        rank: i + 1,
                        title: data.topSongs[i].title,
                        subtitle: data.topSongs[i].artist,
                        value: '${data.topSongs[i].plays}×',
                        fraction: data.topSongs[i].plays / data.topSongs.first.plays,
                        color: accent,
                      ),
                  ],
                  if (data.topArtists.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const _Header('ARTISTAS'),
                    for (var i = 0; i < data.topArtists.length; i++)
                      _RankRow(
                        rank: i + 1,
                        title: data.topArtists[i].artist,
                        value: '${data.topArtists[i].plays}×',
                        fraction: data.topArtists[i].plays / data.topArtists.first.plays,
                        color: accent,
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;

  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      );
}

class _Tile extends StatelessWidget {
  final String value;
  final String label;

  const _Tile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              child: Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Fila del ranking con una barrita proporcional atrás.
class _RankRow extends StatelessWidget {
  final int rank;
  final String title;
  final String? subtitle;
  final String value;
  final double fraction;
  final Color color;

  const _RankRow({
    required this.rank,
    required this.title,
    this.subtitle,
    required this.value,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('$rank', style: const TextStyle(color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.02, 1.0),
                    minHeight: 4,
                    color: color,
                    backgroundColor: Colors.white10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
