import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/app_database.dart';
import 'screens/home_shell.dart';
import 'services/accent_controller.dart';
import 'services/error_log.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'utils/platform.dart';
import 'widgets/desktop.dart';

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
  if (isWindows) {
    // sqflite no tiene versión para Windows: ahí se usa SQLite por FFI,
    // con la base en AppData (y no en la carpeta desde donde se abrió).
    sqfliteFfiInit();
    AppDatabase.factoryOverride = databaseFactoryFfi;
    AppDatabase.pathOverride =
        p.join((await getApplicationSupportDirectory()).path, 'letras.db');
    UpdateService.cleanUpAfterUpdate();
  }
  await SettingsService.loadLivePrefs();
  DesktopWindow.init();
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
          builder: (context, child) => MacWindowInsets(child: child!),
        );
      },
    );
  }
}
