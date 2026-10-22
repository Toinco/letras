import 'package:flutter_test/flutter_test.dart';

import 'package:lyrics_app/services/update_service.dart';

void main() {
  group('Dónde instalar la actualización en la Mac', () {
    Future<bool> Function(String) only(Set<String> writable) =>
        (dir) async => writable.contains(dir);

    test('Si se puede, reemplaza la app donde está', () async {
      final target = await UpdateService.macInstallTarget(
        '/Applications/Letras.app',
        canWrite: only({'/Applications'}),
        home: '/Users/x',
      );
      expect(target, '/Applications/Letras.app');
    });

    test('Abierta desde Descargas (copia de solo lectura): va a Aplicaciones', () async {
      final target = await UpdateService.macInstallTarget(
        '/private/var/folders/nr/abc/T/AppTranslocation/771B9B13/d/Letras.app',
        // Aunque la carpeta temporal dejara escribir, no sirve reemplazarla.
        canWrite: (_) async => true,
        home: '/Users/x',
      );
      expect(target, '/Applications/Letras.app');
    });

    test('Sin permiso en Aplicaciones: usa ~/Applications', () async {
      final target = await UpdateService.macInstallTarget(
        '/private/var/folders/nr/abc/T/AppTranslocation/771B9B13/d/Letras.app',
        canWrite: only({'/Users/x/Applications'}),
        home: '/Users/x',
      );
      expect(target, '/Users/x/Applications/Letras.app');
    });

    test('Sin permiso en ningún lado: null (se muestra el aviso)', () async {
      final target = await UpdateService.macInstallTarget(
        '/Volumes/Letras/Letras.app',
        canWrite: (_) async => false,
        home: '/Users/x',
      );
      expect(target, isNull);
    });
  });
}
