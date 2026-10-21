import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Un error registrado (de red, de la app o un cuelgue).
class ErrorEntry {
  final DateTime time;
  final String source;
  final String message;
  final String? stack;

  const ErrorEntry({required this.time, required this.source, required this.message, this.stack});

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        's': source,
        'm': message,
        if (stack != null) 'st': stack,
      };

  factory ErrorEntry.fromJson(Map<String, dynamic> j) => ErrorEntry(
        time: DateTime.tryParse(j['t'] as String? ?? '') ?? DateTime.now(),
        source: j['s'] as String? ?? '',
        message: j['m'] as String? ?? '',
        stack: j['st'] as String?,
      );

  @override
  String toString() =>
      '[${time.toIso8601String()}] $source: $message${stack == null ? '' : '\n$stack'}';
}

/// Registro de errores tipo Sentry, pero local: guarda los últimos errores
/// (fallas de red después de reintentar, excepciones no atrapadas) en un
/// archivo del teléfono. Se ve y se comparte desde Ajustes > Registro de
/// errores, así si algo falla en el celular de un amigo te lo puede mandar.
class ErrorLog {
  static const _maxEntries = 300;
  static final List<ErrorEntry> _entries = [];
  static bool _loaded = false;
  static File? _file;

  /// Se incrementa con cada error nuevo (para refrescar la pantalla).
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<File> _logFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/error_log.jsonl');
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _logFile();
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          _entries.add(ErrorEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
        } catch (_) {}
      }
    } catch (_) {
      // Sin acceso al disco (tests): queda solo en memoria.
    }
  }

  static Future<void> record(String source, Object error, [StackTrace? stack]) async {
    final entry = ErrorEntry(
      time: DateTime.now(),
      source: source,
      message: error.toString(),
      stack: stack?.toString().split('\n').take(12).join('\n'),
    );
    debugPrint('ErrorLog: $entry');
    await _ensureLoaded();
    _entries.add(entry);
    if (_entries.length > _maxEntries) _entries.removeRange(0, _entries.length - _maxEntries);
    changes.value++;
    try {
      final file = await _logFile();
      // Reescribimos cuando se recorta, si no solo agregamos al final.
      if (_entries.length >= _maxEntries) {
        await file.writeAsString(_entries.map((e) => jsonEncode(e.toJson())).join('\n'));
      } else {
        await file.writeAsString('${jsonEncode(entry.toJson())}\n', mode: FileMode.append);
      }
    } catch (_) {}
  }

  static Future<List<ErrorEntry>> entries() async {
    await _ensureLoaded();
    return List.unmodifiable(_entries.reversed);
  }

  static Future<String> asText() async {
    final list = await entries();
    return list.map((e) => e.toString()).join('\n\n');
  }

  static Future<void> clear() async {
    _entries.clear();
    changes.value++;
    try {
      final file = await _logFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
