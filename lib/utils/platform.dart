import 'package:flutter/foundation.dart';

/// ¿Corre en la Mac? Usa [defaultTargetPlatform] (y no `Platform.isMacOS`)
/// para que los tests, que simulan Android, no cambien según la compu
/// donde se corren.
bool get isMac => defaultTargetPlatform == TargetPlatform.macOS;
