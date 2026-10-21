import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_shell.dart';
import 'services/accent_controller.dart';
import 'services/error_log.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Cualquier error que se escape (de Flutter o de código asíncrono)
  // queda anotado en el registro de errores (Ajustes > Registro de errores).
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    ErrorLog.record('flutter', details.exception, details.stack);
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.record('sin atrapar', error, stack);
    return true;
  };
  await SettingsService.loadLivePrefs();
  runApp(const ProviderScope(child: LyricsApp()));
}

class LyricsApp extends StatelessWidget {
  const LyricsApp({super.key});

  @override
  Widget build(BuildContext context) {
    // El acento de toda la app sigue a la carátula de lo que suena.
    return ValueListenableBuilder<Color>(
      valueListenable: AccentController.color,
      builder: (context, accent, _) {
        final theme = AppTheme.build(accent);
        return MaterialApp(
          title: 'Letras',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: theme,
          themeMode: ThemeMode.dark,
          home: const HomeShell(),
        );
      },
    );
  }
}
