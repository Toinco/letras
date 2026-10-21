import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
/// El repositorio se fija al compilar (`--dart-define=UPDATE_REPO=usuario/repo`):
/// el workflow de GitHub Actions lo pasa solo. En una compilación local,
/// sin ese dato, la búsqueda de actualizaciones no aparece.
class UpdateService {
  static const repo = String.fromEnvironment('UPDATE_REPO');
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
    final suffix = isMac ? '-macos.zip' : '.apk';
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
    final parent = bundle.parent;
    final probe = File('${parent.path}/.letras-update-check');
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw Exception('No hay permiso para escribir en ${parent.path}. '
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
    await Process.start('/bin/sh', [script.path, '$pid', bundle.path, newApp.path],
        mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// Android pide permiso para instalar apps "de esta fuente" la primera vez.
class InstallPermissionNeeded implements Exception {
  const InstallPermissionNeeded();

  @override
  String toString() =>
      'Activa "Permitir de esta fuente" para Letras y vuelve a tocar "Actualizar".';
}
