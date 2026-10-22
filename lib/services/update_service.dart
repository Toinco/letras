import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/platform.dart';
import 'app_http.dart';

/// Una versión publicada en GitHub Releases.
class AppRelease {
  final String version;
  final String notes;
  final String downloadUrl;
  final int? downloadSize;

  const AppRelease({required this.version, required this.notes, required this.downloadUrl, this.downloadSize});
}

/// Actualizaciones automáticas desde GitHub Releases: la app compara su
/// versión con la última publicada y, si hay una nueva, baja el APK y abre
/// el instalador de Android. Así a tus amigos les llegan las versiones
/// nuevas sin pasarles el APK a mano.
///
/// En la Mac baja `letras-X.Y.Z-macos.zip`, cierra la app, reemplaza
/// Letras.app por la nueva y la vuelve a abrir.
///
/// En Windows baja `letras-X.Y.Z-windows.zip` y copia los archivos nuevos
/// encima de los de la carpeta de Letras (los que están en uso se renombran
/// a `.old` y se borran al volver a abrir).
///
/// El repositorio se puede cambiar al compilar
/// (`--dart-define=UPDATE_REPO=usuario/repo`); si no se pasa, se usa el
/// oficial, así también las compilaciones locales pueden actualizarse.
class UpdateService {
  static const repo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'Toinco/letras');
  static const _channel = MethodChannel('io.letras.app/now_playing');

  static bool get isConfigured => repo.contains('/');

  Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// "1.10.0" > "1.9.3". Ignora una "v" adelante y lo que venga después de
  /// un "+" o "-".
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .replaceFirst(RegExp(r'^v'), '')
        .split(RegExp(r'[+-]'))
        .first
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final pa = parts(a);
    final pb = parts(b);
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// La última versión publicada si es más nueva que la instalada; si no, `null`.
  Future<AppRelease?> checkForUpdate() async {
    if (!isConfigured) return null;
    final response = await AppHttp.get(
      Uri.https('api.github.com', '/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
      tag: 'github',
    );
    if (response.statusCode == 404) return null; // todavía no hay releases
    if (response.statusCode != 200) {
      throw Exception('GitHub respondió ${response.statusCode}');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final assets = (json['assets'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final suffix = isMac
        ? '-macos.zip'
        : isWindows
            ? '-windows.zip'
            : '.apk';
    final apk = assets.where((a) => (a['name'] as String? ?? '').endsWith(suffix)).firstOrNull;
    if (apk == null) return null;
    if (compareVersions(tag, await currentVersion()) <= 0) return null;
    return AppRelease(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      notes: json['body'] as String? ?? '',
      downloadUrl: apk['browser_download_url'] as String,
      downloadSize: (apk['size'] as num?)?.toInt(),
    );
  }

  /// Baja el APK (informando el progreso de 0 a 1) y abre el instalador.
  Future<void> downloadAndInstall(AppRelease release, {void Function(double)? onProgress}) async {
    if (isMac) return _updateMac(release, onProgress: onProgress);
    if (isWindows) return _updateWindows(release, onProgress: onProgress);
    final canInstall = await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    if (!canInstall) {
      await _channel.invokeMethod('openInstallPermissionSettings');
      throw const InstallPermissionNeeded();
    }
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    final file = File('${dir.path}/letras-${release.version}.apk');
    await _download(release, file, onProgress);
    await _channel.invokeMethod('installApk', {'path': file.path});
  }

  Future<void> _download(AppRelease release, File file, void Function(double)? onProgress) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(release.downloadUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('No se pudo bajar la actualización (${response.statusCode}).');
      }
      final total = response.contentLength > 0 ? response.contentLength : (release.downloadSize ?? 0);
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  /// Baja el ZIP, lo descomprime y deja un script que espera a que la app
  /// se cierre, cambia Letras.app por la nueva y la vuelve a abrir.
  Future<void> _updateMac(AppRelease release, {void Function(double)? onProgress}) async {
    // .../Letras.app/Contents/MacOS/Letras
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent;
    if (!bundle.path.endsWith('.app')) {
      throw Exception('No se encontró Letras.app para reemplazarla.');
    }
    final target = await macInstallTarget(bundle.path);
    if (target == null) {
      throw Exception('No hay permiso para escribir en Aplicaciones. '
          'Mueve Letras a la carpeta Aplicaciones y vuelve a intentar.');
    }

    final dir = Directory('${(await getTemporaryDirectory()).path}/letras-update');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final zip = File('${dir.path}/letras.zip');
    await _download(release, zip, onProgress);

    final unzip = await Process.run('/usr/bin/ditto', ['-x', '-k', zip.path, dir.path]);
    if (unzip.exitCode != 0) throw Exception('No se pudo descomprimir la actualización.');
    final newApp = Directory('${dir.path}/Letras.app');
    if (!await newApp.exists()) throw Exception('La actualización no trae Letras.app.');

    final script = File('${dir.path}/instalar.sh');
    await script.writeAsString('''
#!/bin/sh
while kill -0 "\$1" 2>/dev/null; do sleep 0.2; done
rm -rf "\$2" && /usr/bin/ditto "\$3" "\$2"
/usr/bin/xattr -dr com.apple.quarantine "\$2" 2>/dev/null
/usr/bin/open "\$2"
''');
    await Process.start('/bin/sh', [script.path, '$pid', target, newApp.path],
        mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Dónde dejar la Letras.app nueva. Normalmente, encima de la actual.
  ///
  /// Pero si la app se abrió sin moverla de Descargas, macOS la ejecuta desde
  /// una copia de solo lectura (".../AppTranslocation/..."), y esa copia no
  /// se puede reemplazar. En ese caso (o si no hay permiso en su carpeta) se
  /// instala en Aplicaciones, o en ~/Applications si Aplicaciones no deja.
  /// `null` si no se puede escribir en ningún lado.
  static Future<String?> macInstallTarget(
    String bundlePath, {
    Future<bool> Function(String dir)? canWrite,
    String? home,
  }) async {
    final writable = canWrite ?? _canWrite;
    final parent = p.dirname(bundlePath);
    final translocated = bundlePath.contains('/AppTranslocation/');
    if (!translocated && await writable(parent)) return bundlePath;
    final userHome = home ?? Platform.environment['HOME'];
    for (final dir in [
      '/Applications',
      if (userHome != null && userHome.isNotEmpty) p.join(userHome, 'Applications'),
    ]) {
      if (await writable(dir)) return p.join(dir, 'Letras.app');
    }
    return null;
  }

  static Future<bool> _canWrite(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final probe = File(p.join(dir, '.letras-update-check'));
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Lista de los `.old` que dejó la última actualización de Windows.
  static Future<File> _oldFilesList() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'actualizacion_old.txt'));

  /// Baja el ZIP, lo descomprime y copia los archivos nuevos en la carpeta
  /// de Letras. Windows no deja pisar el .exe ni las DLL en uso, pero sí
  /// renombrarlas: las actuales pasan a `.old`, se copian las nuevas, se
  /// abre la versión nueva y esta se cierra.
  Future<void> _updateWindows(AppRelease release, {void Function(double)? onProgress}) async {
    final exe = File(Platform.resolvedExecutable);
    final appDir = exe.parent;
    final probe = File(p.join(appDir.path, '.letras-update-check'));
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw Exception('No hay permiso para escribir en ${appDir.path}. '
          'Mueve la carpeta de Letras a tu carpeta de usuario y vuelve a intentar.');
    }

    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'letras-update'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final zip = File(p.join(dir.path, 'letras.zip'));
    await _download(release, zip, onProgress);
    final unzipped = p.join(dir.path, 'nuevo');
    await extractFileToDisk(zip.path, unzipped);
    final newDir = Directory(p.join(unzipped, 'Letras'));
    if (!await File(p.join(newDir.path, 'Letras.exe')).exists()) {
      throw Exception('La actualización no trae Letras.exe.');
    }

    final moved = <String>[];
    try {
      await for (final entity in newDir.list(recursive: true)) {
        if (entity is! File) continue;
        final target = File(p.join(appDir.path, p.relative(entity.path, from: newDir.path)));
        await target.parent.create(recursive: true);
        if (await target.exists()) {
          final old = File('${target.path}.old');
          if (await old.exists()) await old.delete();
          await target.rename(old.path);
          moved.add(old.path);
        }
        await entity.copy(target.path);
      }
    } catch (_) {
      // Vuelve todo como estaba.
      for (final old in moved.reversed) {
        final original = old.substring(0, old.length - '.old'.length);
        try {
          File(original).deleteSync();
        } catch (_) {}
        try {
          File(old).renameSync(original);
        } catch (_) {}
      }
      rethrow;
    }
    await (await _oldFilesList()).writeAsString(moved.join('\n'));

    // "--actualizado": la nueva espera a que esta se cierre (ver main.cpp).
    await Process.start(exe.path, ['--actualizado'], mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Al abrir la app en Windows: borra los `.old` de la última actualización.
  static Future<void> cleanUpAfterUpdate() async {
    if (!isWindows) return;
    try {
      final list = await _oldFilesList();
      if (!await list.exists()) return;
      for (final path in await list.readAsLines()) {
        if (!path.endsWith('.old')) continue;
        try {
          await File(path).delete();
        } catch (_) {}
      }
      await list.delete();
    } catch (_) {}
  }
}

/// Android pide permiso para instalar apps "de esta fuente" la primera vez.
class InstallPermissionNeeded implements Exception {
  const InstallPermissionNeeded();

  @override
  String toString() =>
      'Activa "Permitir de esta fuente" para Letras y vuelve a tocar "Actualizar".';
}
