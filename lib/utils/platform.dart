import 'package:flutter/foundation.dart';

/// ¿Corre en la Mac? Usa [defaultTargetPlatform] (y no `Platform.isMacOS`)
/// para que los tests, que simulan Android, no cambien según la compu
/// donde se corren.
bool get isMac => defaultTargetPlatform == TargetPlatform.macOS;

/// ¿Corre en Windows? (igual que [isMac], según [defaultTargetPlatform]).
bool get isWindows => defaultTargetPlatform == TargetPlatform.windows;

/// Mac o Windows: ventana de compu, sin permisos de Android.
bool get isDesktop => isMac || isWindows;
