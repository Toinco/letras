import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/platform.dart';

/// Desde qué ancho la app usa el diseño de escritorio (menú lateral,
/// carátula grande al costado de la letra, contenido centrado).
const double kWideLayoutBreakpoint = 760;

bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;

/// La ventana de la compu. En la Mac su barra de título es transparente y
/// el contenido llega hasta arriba (ver MainFlutterWindow.swift); en Windows
/// la barra es la común (ver windows/runner/flutter_window.cpp).
class DesktopWindow {
  static const macTitleBarHeight = 28.0;
  static const _channel = MethodChannel('io.letras.app/window');

  /// Si la ventana está en pantalla completa (sin barra de título).
  static final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  static void init() {
    if (!isDesktop) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreenChanged') fullScreen.value = call.arguments == true;
    });
    _channel
        .invokeMethod<bool>('isFullScreen')
        .then((v) => fullScreen.value = v ?? false)
        .catchError((_) => false);
  }

  static Future<void> toggleFullScreen() async {
    try {
      await _channel.invokeMethod('toggleFullScreen');
    } on MissingPluginException {
      // Fuera de la compu.
    }
  }
}

/// Deja libre arriba el alto de la barra de título de la Mac (donde están
/// los tres botones), como si fuera la barra de estado del teléfono: así
/// AppBar y SafeArea se corren solos y los fondos siguen llegando arriba.
class MacWindowInsets extends StatelessWidget {
  final Widget child;

  const MacWindowInsets({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!isMac) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopWindow.fullScreen,
      builder: (context, full, _) {
        final mq = MediaQuery.of(context);
        final top = full ? 0.0 : DesktopWindow.macTitleBarHeight;
        return MediaQuery(
          data: mq.copyWith(
            padding: mq.padding.copyWith(top: top),
            viewPadding: mq.viewPadding.copyWith(top: top),
          ),
          child: child,
        );
      },
    );
  }
}

/// Fondo de las pantallas de listas: negro, con un brillo suave del color
/// de la carátula de lo que suena arriba (antes era negro liso y la app se
/// sentía apagada fuera de Reproduciendo).
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final hsl = HSLColor.fromColor(accent);
    // Un segundo tono vecino, para que el brillo no sea de un solo color.
    final second = hsl.withHue((hsl.hue + 40) % 360).toColor();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      decoration: const BoxDecoration(color: AppTheme.background),
      foregroundDecoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.9, -1.15),
          radius: 1.4,
          colors: [accent.withValues(alpha: 0.40), accent.withValues(alpha: 0.0)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.0, -0.9),
            radius: 1.0,
            colors: [second.withValues(alpha: 0.22), second.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}

/// Envuelve cada pantalla de listas: pone el [AmbientBackground] detrás y,
/// en pantallas anchas, centra la pantalla (barra de arriba incluida) en
/// una columna cómoda de leer, en vez de estirar listas y textos de punta
/// a punta.
class ReadableFrame extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ReadableFrame({super.key, required this.child, this.maxWidth = 860});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scaffold y barra transparentes para que se vea el fondo.
    final see = Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Colors.transparent),
      ),
      child: child,
    );
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > maxWidth + 48;
      return Stack(
        fit: StackFit.expand,
        children: [
          const AmbientBackground(),
          if (wide) Center(child: SizedBox(width: maxWidth, child: see)) else see,
        ],
      );
    });
  }
}

/// Hoja de abajo en el teléfono; en pantallas anchas, un diálogo centrado
/// (una hoja que sube desde abajo de una ventana de compu se ve fuera de
/// lugar). Recibe lo mismo que [showModalBottomSheet].
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
  bool isScrollControlled = false,
}) {
  if (!isWideLayout(context)) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      shape: shape,
      isScrollControlled: isScrollControlled,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: backgroundColor ?? AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _InDialog(child: Builder(builder: builder)),
      ),
    ),
  );
}

class _InDialog extends InheritedWidget {
  const _InDialog({required super.child});

  @override
  bool updateShouldNotify(_InDialog oldWidget) => false;
}

/// La rayita para arrastrar arriba de una hoja. En un diálogo no va.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.dependOnInheritedWidgetOfExactType<_InDialog>() != null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
