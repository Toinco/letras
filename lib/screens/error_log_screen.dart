import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/error_log.dart';
import '../theme/app_theme.dart';

/// Los últimos errores de la app (fallas de red, cuelgues...), para
/// mandárselos a quien la mantiene si algo anda mal.
class ErrorLogScreen extends StatefulWidget {
  const ErrorLogScreen({super.key});

  @override
  State<ErrorLogScreen> createState() => _ErrorLogScreenState();
}

class _ErrorLogScreenState extends State<ErrorLogScreen> {
  List<ErrorEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    ErrorLog.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    ErrorLog.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await ErrorLog.entries();
    if (mounted) setState(() => _entries = entries);
  }

  String _time(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Registro de errores'),
        actions: [
          IconButton(
            tooltip: 'Compartir',
            icon: const Icon(Icons.share_rounded),
            onPressed: _entries.isEmpty
                ? null
                : () async => SharePlus.instance.share(ShareParams(
                      text: await ErrorLog.asText(),
                      subject: 'Registro de errores de Letras',
                    )),
          ),
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: _entries.isEmpty ? null : ErrorLog.clear,
          ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(
              child: Text('Sin errores registrados.', style: TextStyle(color: AppTheme.textSecondary)),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = _entries[i];
                return ListTile(
                  title: Text(e.message, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${_time(e.time)} · ${e.source}',
                      style: const TextStyle(color: AppTheme.textSecondary)),
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: e.toString()));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Copiado.')));
                  },
                );
              },
            ),
    );
  }
}
