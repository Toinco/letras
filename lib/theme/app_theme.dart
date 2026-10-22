import 'dart:io';

import 'package:flutter/material.dart';

/// Tema oscuro, minimalista, inspirado en Apple Music: fondo negro,
/// acentos rojos/rosados, tipografía grande y limpia, bordes redondeados.
class AppTheme {
  static const Color background = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF1C1C1E);

  /// Menú lateral en pantallas anchas.
  static const Color sidebar = Color(0xFF111113);
  /// Rojo estilo Apple Music: el acento por defecto. El acento real de
  /// cada pantalla sale de `Theme.of(context).colorScheme.primary`, que
  /// cambia con la carátula de lo que suena (ver AccentController).
  static const Color brandAccent = Color(0xFFFC3C44);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFF8E8E93);

  static ThemeData get dark => build(brandAccent);

  /// En la Mac (y iPhone) se usa la tipografía del sistema, San Francisco.
  /// En Windows y Linux, Inter (incluida en la app), que es casi igual: así
  /// la app se ve igual en todas las compus. San Francisco no se puede
  /// incluir fuera de Apple por su licencia.
  static String? get fontFamily => (Platform.isWindows || Platform.isLinux) ? 'Inter' : null;

  static ThemeData build(Color accent) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: fontFamily,
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      primaryColor: accent,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accent,
        surface: surface,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        // Sin el tinte que Material 3 le pone al scrollear: la barra queda
        // del mismo negro que el fondo.
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: const Color(0xFF121212),
        selectedItemColor: accent,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.18),
        selectedIconTheme: IconThemeData(color: accent),
        unselectedIconTheme: const IconThemeData(color: textSecondary),
        selectedLabelTextStyle:
            TextStyle(
                fontFamily: fontFamily, color: accent, fontSize: 11.5, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: TextStyle(fontFamily: fontFamily, color: textSecondary, fontSize: 11.5),
        minWidth: 84,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.all(Colors.white24),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(fontFamily: fontFamily, color: Colors.white, fontSize: 12),
      ),
      chipTheme: ChipThemeData(
        selectedColor: accent.withValues(alpha: 0.25),
        checkmarkColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.white : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : null,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2C2C2E),
        contentTextStyle: TextStyle(fontFamily: fontFamily, color: Colors.white),
        actionTextColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          textStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        // Translúcido: deja ver el brillo de color del fondo.
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        hintStyle: TextStyle(fontFamily: fontFamily, color: textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}
