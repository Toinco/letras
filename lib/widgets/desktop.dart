import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/platform.dart';

/// Desde qué ancho la app usa el diseño de escritorio (menú lateral,
/// carátula grande al costado de la letra, contenido centrado).
const double kWideLayoutBreakpoint = 760;

bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;

/// La ventana de la Mac: su barra de título es transparente y el contenido
/// llega hasta arriba (ver MainFlutterWindow.swift).
class MacWindow {
  static const titleBarHeight = 28.0;
  static const _channel = MethodChannel('io.letras.app/window');

  /// Si la ventana está en pantalla completa (sin barra de título).
  static final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  static void init() {
    if (!isMac) return;
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
      // Fuera de la Mac.
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
      valueListenable: MacWindow.fullScreen,
      builder: (context, full, _) {
        final mq = MediaQuery.of(context);
        final top = full ? 0.0 : MacWindow.titleBarHeight;
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

/// En pantallas anchas centra la pantalla (barra de arriba incluida) en
/// una columna cómoda de leer, en vez de estirar listas y textos de punta
/// a punta. En el teléfono no hace nada.
class ReadableFrame extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ReadableFrame({super.key, required this.child, this.maxWidth = 860});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth <= maxWidth + 48) return child;
      return ColoredBox(
        color: AppTheme.background,
        child: Center(child: SizedBox(width: maxWidth, child: child)),
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
