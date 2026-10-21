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
}
