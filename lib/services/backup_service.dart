import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics_storage_service.dart';
import 'playlist_service.dart';
import 'settings_service.dart';
import 'stats_service.dart';

/// Qué trajo una copia de seguridad al importarla.
class ImportSummary {
  final int lyricsAdded;
  final int lyricsTotal;
  final int playlists;
  final int plays;

  const ImportSummary({
    required this.lyricsAdded,
    required this.lyricsTotal,
    required this.playlists,
    required this.plays,
  });
}

/// Exporta e importa todas las descargas (letras, traducciones,
/// carátulas, playlists, estadísticas y ajustes de sincronización) en un
/// solo archivo ZIP. Sirve para pasar todo a otro teléfono o guardar una
/// copia. Las API keys NO se incluyen.
class BackupService {
  static const _format = 1;

  // Preferencias que viajan en la copia (desfases e historial). Nada de
  // tokens ni claves.
  static const _prefsToCopy = ['sync_offsets_ms', 'app_offsets_ms', 'listening_history'];

  final LyricsStorageService _storage;
  final PlaylistService _playlists;
  final StatsService _stats;

  BackupService({LyricsStorageService? storage, PlaylistService? playlists, StatsService? stats})
      : _storage = storage ?? LyricsStorageService(),
        _playlists = playlists ?? PlaylistService(),
        _stats = stats ?? StatsService();

  /// Arma el ZIP en memoria.
  Future<Uint8List> buildZip() async {
    final archive = Archive();
    void addJson(String name, Object data) =>
        archive.addFile(ArchiveFile.string(name, jsonEncode(data)));

    final rows = await _storage.exportRows();
    addJson('manifest.json', {
      'app': 'letras',
      'format': _format,
      'exportedAt': DateTime.now().toIso8601String(),
      'lyrics': rows.length,
    });
    addJson('lyrics.json', rows);
    addJson('playlists.json', await _playlists.exportData());
    addJson('plays.json', await _stats.exportRows());

    final prefs = await SharedPreferences.getInstance();
    addJson('prefs.json', {
      for (final k in _prefsToCopy)
        if (prefs.get(k) != null) k: prefs.get(k),
    });

    for (final entry in (await _storage.artworkFiles()).entries) {
      try {
        archive.addFile(ArchiveFile.bytes('artwork/${entry.key}.art', await entry.value.readAsBytes()));
      } catch (_) {}
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// Arma el ZIP y abre el menú de compartir de Android (Drive, WhatsApp,
  /// guardar en Archivos...).
  Future<void> exportAndShare() async {
    final bytes = await buildZip();
    final dir = await getTemporaryDirectory();
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final file = File('${dir.path}/letras-$date.zip');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/zip')],
      subject: 'Copia de seguridad de Letras ($date)',
    ));
  }

  /// Deja elegir un ZIP y lo importa. `null` si se canceló.
  Future<ImportSummary?> pickAndImport({bool overwrite = false}) async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty) return null;
    final bytes = await picked.first.readAsBytes();
    return importZip(bytes, overwrite: overwrite);
  }

  Future<ImportSummary> importZip(List<int> bytes, {bool overwrite = false}) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('El archivo no es un ZIP válido.');
    }
    dynamic readJson(String name) {
      final f = archive.findFile(name);
      if (f == null) return null;
      return jsonDecode(utf8.decode(f.content));
    }

    final manifest = readJson('manifest.json');
    if (manifest is! Map || manifest['app'] != 'letras') {
      throw const FormatException('Este ZIP no es una copia de seguridad de Letras.');
    }
    if ((manifest['format'] as int? ?? 0) > _format) {
      throw const FormatException('La copia es de una versión más nueva de la app. Actualízala.');
    }

    final rows = ((readJson('lyrics.json') as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
    final added = await _storage.importRows(rows, overwrite: overwrite);

    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith('artwork/') || !f.name.endsWith('.art')) continue;
      final key = f.name.substring('artwork/'.length, f.name.length - 4);
      try {
        await _storage.saveArtwork(key, f.content);
      } catch (_) {}
    }

    final playlists = readJson('playlists.json');
    if (playlists is Map<String, dynamic>) await _playlists.importData(playlists);

    final plays = ((readJson('plays.json') as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
    await _stats.importRows(plays);

    final prefsData = readJson('prefs.json');
    if (prefsData is Map<String, dynamic>) {
      final prefs = await SharedPreferences.getInstance();
      for (final k in _prefsToCopy) {
        final v = prefsData[k];
        // No pisamos lo que ya hay en este teléfono.
        if (v == null || prefs.get(k) != null) continue;
        if (v is String) await prefs.setString(k, v);
        if (v is List) await prefs.setStringList(k, v.cast<String>());
      }
      await SettingsService.loadLivePrefs();
    }

    return ImportSummary(
      lyricsAdded: added,
      lyricsTotal: rows.length,
      playlists: ((playlists as Map?)?['playlists'] as List?)?.length ?? 0,
      plays: plays.length,
    );
  }
}
