// Test básico: verifica que la app arranca y muestra la barra de
// navegación inferior sin tirar errores.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lyrics_app/main.dart';

void main() {
  testWidgets('La app arranca y muestra la pestaña Reproduciendo', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // Canal nativo simulado: sin permiso de notificaciones.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('io.letras.app/now_playing'),
      (call) async => call.method == 'isNotificationAccessGranted' ? false : null,
    );
    await tester.pumpWidget(const ProviderScope(child: LyricsApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Reproduciendo'), findsWidgets);
    // Sin permiso de notificaciones, ofrece darlo o usar el micrófono.
    expect(find.text('Dar acceso'), findsOneWidget);
    expect(find.text('O escuchar con el micrófono'), findsOneWidget);

    // Al desarmar todo no quedan timers colgando (el controlador se libera).
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('io.letras.app/now_playing'),
      (call) async => call.method == 'isNotificationAccessGranted' ? false : null,
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: LyricsApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('En el teléfono la navegación va abajo', (tester) async {
    await pumpAt(tester, const Size(400, 850));
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('En una ventana ancha la navegación va al costado', (tester) async {
    await pumpAt(tester, const Size(1200, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
    // Ajustes está en el menú lateral.
    expect(find.byTooltip('Ajustes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
