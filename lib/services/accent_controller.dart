import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'settings_service.dart';

/// Color de acento de toda la app, sacado de la carátula de lo que suena
/// (como Apple Music). Si en Ajustes está apagado, o no hay carátula,
/// vuelve al rojo de siempre.
class AccentController {
  static final ValueNotifier<Color> color = ValueNotifier(AppTheme.brandAccent);

  static int? _lastKey;
  static final Map<int, Color> _cache = {};

  static int _keyFor(Uint8List bytes) {
    // Huella rápida: largo + algunos bytes de muestra (son JPEG chicos).
    var h = bytes.length;
    final step = (bytes.length ~/ 32).clamp(1, bytes.length);
    for (var i = 0; i < bytes.length; i += step) {
      h = (h * 31 + bytes[i]) & 0x7fffffff;
    }
    return h;
  }

  /// Calcula el acento a partir de [bytes] (la carátula). `null` = volver
  /// al color por defecto.
  static Future<void> updateFromArtwork(Uint8List? bytes) async {
    if (!SettingsService.dynamicAccent.value || bytes == null || bytes.isEmpty) {
      _lastKey = null;
      color.value = AppTheme.brandAccent;
      return;
    }
    final key = _keyFor(bytes);
    if (key == _lastKey) return;
    _lastKey = key;
    final cached = _cache[key];
    if (cached != null) {
      color.value = cached;
      return;
    }
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: ResizeImage(MemoryImage(bytes), width: 96, height: 96),
        brightness: Brightness.dark,
      );
      final accent = usable(scheme.primary);
      _cache[key] = accent;
      // Si mientras calculábamos cambió la canción, no pisamos el nuevo.
      if (_lastKey == key) color.value = accent;
    } catch (_) {
      if (_lastKey == key) color.value = AppTheme.brandAccent;
    }
  }

  /// Ajusta un color para que sirva de acento sobre fondo negro: ni muy
  /// oscuro (no se vería) ni muy lavado (parecería gris).
  static Color usable(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness(hsl.lightness.clamp(0.55, 0.72))
        .withSaturation(hsl.saturation < 0.15 ? hsl.saturation : hsl.saturation.clamp(0.5, 0.95))
        .toColor();
  }
}
