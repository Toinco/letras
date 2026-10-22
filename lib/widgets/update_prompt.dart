import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/update_service.dart';

/// Avisa cuando hay una versión nueva y la instala con un toque, sin tener
/// que bajar el archivo a mano.
class UpdatePrompt {
  static const _skippedVersionKey = 'update_skipped_version';
  static const _skippedAtKey = 'update_skipped_at';

  /// Si al tocar "Más tarde" se vuelve a preguntar al abrir la app.
  static const _askAgainAfter = Duration(days: 2);

  /// La versión nueva encontrada (o `null`): Ajustes la muestra destacada.
  static final ValueNotifier<AppRelease?> available = ValueNotifier(null);

  static bool _checkedThisLaunch = false;

  /// Al abrir la app: busca en silencio y, si hay una versión nueva,
  /// pregunta si instalarla. Sin conexión no dice nada.
  static Future<void> checkOnStartup(BuildContext context) async {
    if (_checkedThisLaunch || !UpdateService.isConfigured) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _checkedThisLaunch = true;
    // Un rato después de abrir, para no competir con la letra.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!context.mounted) return;
    final AppRelease? release;
    try {
      release = await UpdateService().checkForUpdate();
    } catch (_) {
      return;
    }
    if (release == null) return;
    available.value = release;

    final prefs = await SharedPreferences.getInstance();
    final skippedAt = prefs.getInt(_skippedAtKey) ?? 0;
    final recentlySkipped = prefs.getString(_skippedVersionKey) == release.version &&
        DateTime.now().millisecondsSinceEpoch - skippedAt < _askAgainAfter.inMilliseconds;
    if (recentlySkipped || !context.mounted) return;

    final accepted = await confirm(context, release);
    if (accepted == true) {
      if (context.mounted) await install(context, release);
    } else {
      await prefs.setString(_skippedVersionKey, release.version);
      await prefs.setInt(_skippedAtKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// "Versión X disponible" con las novedades: `true` si se toca Actualizar.
  static Future<bool?> confirm(BuildContext context, AppRelease release) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Versión ${release.version} disponible'),
        content: SingleChildScrollView(
          child: Text(release.notes.trim().isEmpty ? 'Hay una versión nueva.' : release.notes),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Más tarde')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Actualizar'),
          ),
        ],
      ),
    );
  }

  /// Baja la versión nueva mostrando el progreso y la instala. En la compu
  /// la app se cierra y se vuelve a abrir sola ya actualizada.
  static Future<void> install(BuildContext context, AppRelease release) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final progress = ValueNotifier<double?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('Descargando ${release.version}...'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: 10),
              Text(
                v == null ? 'Conectando...' : '${(v * 100).round()} %',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      await UpdateService().downloadAndInstall(release, onProgress: (p) => progress.value = p);
      navigator.pop();
    } catch (e) {
      navigator.pop();
      messenger?.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }
}
