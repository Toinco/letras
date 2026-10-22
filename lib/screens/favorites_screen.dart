import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_card.dart';
import 'lyrics_screen.dart';
import 'settings_screen.dart';
import '../providers.dart';
import '../widgets/desktop.dart';

/// Canciones que el usuario le dio "me gusta" en Spotify, con acceso
/// rápido para ver o descargar la letra de cada una (o de todas).
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  late final _spotifyAuth = ref.read(spotifyAuthProvider);
  late final _spotifyService = ref.read(spotifyProvider);
  late final _storage = ref.read(storageProvider);
  late final _translationService = ref.read(translationProvider);
  late final _artworkService = ref.read(artworkProvider);
  late final _settingsService = ref.read(settingsProvider);
  late final _syncService = ref.read(favoritesSyncProvider);

  bool _checking = true;
  bool _connected = false;
  bool _connecting = false;
  bool _autoDownload = false;

  final List<Song> _songs = [];
  String? _nextUrl;
  int _total = 0;
  bool _loadingFirstPage = false;
  bool _loadingMore = false;
  String? _error;

  bool _bulkRunning = false;
  bool _bulkCancelled = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;
  int _bulkNew = 0;
  int _bulkSkipped = 0;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    final connected = await _spotifyAuth.isConnected();
    final autoDownload = await _settingsService.getAutoDownloadFavorites();
    if (!mounted) return;
    setState(() {
      _connected = connected;
      _autoDownload = autoDownload;
      _checking = false;
    });
    if (connected) _loadFirstPage();
  }

  Future<void> _setAutoDownload(bool value) async {
    setState(() => _autoDownload = value);
    await _settingsService.setAutoDownloadFavorites(value);
    if (value) _bulkDownloadAll();
  }

  Future<void> _connect() async {
    final clientId = await _spotifyAuth.getClientId();
    if (clientId.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Primero carga el Client ID de Spotify en Ajustes.'),
          ),
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
      }
      return;
    }

    setState(() => _connecting = true);
    try {
      await _spotifyAuth.connect();
      if (mounted) {
        setState(() {
          _connected = true;
          _connecting = false;
        });
        _loadFirstPage();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _connecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    await _spotifyAuth.disconnect();
    if (mounted) {
      setState(() {
        _connected = false;
        _songs.clear();
        _nextUrl = null;
      });
    }
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loadingFirstPage = true;
      _error = null;
    });
    try {
      final page = await _spotifyService.getLikedSongs();
      if (!mounted) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(page.songs);
        _nextUrl = page.nextUrl;
        _total = page.total;
        _loadingFirstPage = false;
      });
      // Si el usuario activó la descarga automática, revisamos toda la
      // biblioteca por si hay canciones nuevas ("me gusta" recientes) sin
      // descargar todavía.
      if (_autoDownload) _bulkDownloadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFirstPage = false;
        _error = 'No se pudo cargar tu biblioteca: $e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_nextUrl == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _spotifyService.getLikedSongs(pageUrl: _nextUrl);
      if (!mounted) return;
      setState(() {
        _songs.addAll(page.songs);
        _nextUrl = page.nextUrl;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo cargar más: $e')),
      );
    }
  }

  Future<void> _openSongSheet(Song song) {
    return showSongActionsSheet(
      context,
      song: song,
      onViewLyrics: () => _viewLyrics(song),
      onDownload: () => _downloadSong(song, silent: false),
    );
  }

  Future<void> _viewLyrics(Song song) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final saved = await _storage.getSaved(song.title, song.artist);
      final result = saved ??
          await ref.read(lyricsFinderProvider).find(song.title, song.artist, durationSeconds: song.durationSeconds);
      if (!mounted) return;
      Navigator.of(context).pop(); // cierra el loading
      if (result != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LyricsScreen(result: result, originalSong: song),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró la letra de esta canción.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error buscando la letra: $e')),
      );
    }
  }

  /// Descarga la letra (+ traducción) de una canción. Si ya está
  /// descargada, no hace nada. Devuelve true si quedó descargada.
  Future<bool> _downloadSong(Song song, {required bool silent}) async {
    try {
      if (await _storage.isSaved(song.title, song.artist)) {
        // Ya estaba descargada (por aquí o por otro lado): la marcamos como
        // vinculada a tus me gusta igual, para que si más adelante le
        // sacas el "me gusta" se borre en la próxima sincronización.
        await _storage.markSpotifyLinked(song.title, song.artist);
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ya la habías descargado.')),
          );
        }
        return true;
      }

      final result = await ref.read(lyricsFinderProvider).find(song.title, song.artist, durationSeconds: song.durationSeconds);
      if (result == null) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se encontró la letra de esta canción.')),
          );
        }
        return false;
      }

      List<String>? translated;
      if (result.hasSyncedLyrics) {
        translated = await _translationService.translate(
          result.syncedLyrics.map((l) => l.text).toList(),
        );
      }
      // Spotify ya nos da la URL de la carátula: la bajamos directo, sin
      // tener que buscarla en iTunes.
      final artwork = await _artworkService.fetchArtworkBytes(
        song.title,
        song.artist,
        knownUrl: song.artworkUrl,
      );
      // Guardamos con el título/artista de Spotify (no el que devuelve
      // LRCLIB, que puede venir levemente distinto): así, la próxima vez
      // que se chequee "¿ya la tengo?" contra tu biblioteca de Spotify, la
      // clave coincide y no se vuelve a descargar de nuevo.
      await _storage.save(
        result.copyWith(translatedLines: translated, translationLang: SettingsService.translationLang.value, song: result.song.withIdentityFrom(song)),
        artworkBytes: artwork,
      );
      await _storage.markSpotifyLinked(song.title, song.artist);

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Letra descargada.')),
        );
      }
      return true;
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo descargar: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _downloadAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Descargar todas'),
        content: Text(
          'Vamos a buscar y descargar la letra de tus $_total canciones que '
          'te gustan (salteando las que ya tengas). Puede tardar varios '
          'minutos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Descargar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _bulkDownloadAll();
  }

  /// Recorre toda la biblioteca de "me gusta" (paginando desde donde
  /// vayamos), descarga la letra de lo que todavía no esté descargado
  /// (salteando rápido, sin red ni espera, lo que ya está), y borra lo que
  /// hayas sacado de tus "me gusta" desde la última vez. Usa el mismo
  /// servicio que corre solo apenas se abre la app (FavoritesSyncService),
  /// así el comportamiento es idéntico, con o sin esta pantalla abierta.
  Future<void> _bulkDownloadAll() async {
    // Ojo: no chequeamos `_syncService.isRunning` aquí. Si ya hay una
    // sincronización corriendo (por ejemplo, la automática que arranca
    // sola al abrir la app), `_syncService.sync()` se engancha a esa
    // misma en vez de arrancar otra, y nos va a ir pasando su progreso
    // real. Antes, si ya estaba corriendo, esto cortaba aquí sin avisar
    // nada, y el botón "Descargar todas" parecía no hacer nada.
    if (_bulkRunning) return;

    setState(() {
      _bulkRunning = true;
      _bulkCancelled = false;
      _bulkDone = 0;
      _bulkTotal = 0;
      _bulkNew = 0;
      _bulkSkipped = 0;
    });

    try {
      final result = await _syncService.sync(
        knownFirstPage: List<Song>.from(_songs),
        knownNextUrl: _nextUrl,
        isCancelled: () => _bulkCancelled,
        onProgress: (done, total, skipped, downloaded) {
          if (!mounted) return;
          setState(() {
            _bulkDone = done;
            _bulkTotal = total;
            _bulkSkipped = skipped;
            _bulkNew = downloaded;
          });
        },
      );

      if (result.error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Se interrumpió la descarga: ${result.error}')),
        );
      } else if (mounted && result.removedStale > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.removedStale == 1
                ? 'Se borró 1 letra de una canción que sacaste de tus me gusta.'
                : 'Se borraron ${result.removedStale} letras de canciones que sacaste de tus me gusta.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Favoritos'),
          actions: [
            if (_connected)
              IconButton(
                tooltip: 'Desconectar Spotify',
                icon: const Icon(Icons.link_off_rounded),
                onPressed: _disconnect,
              ),
          ],
        ),
        body: _checking
            ? const Center(child: CircularProgressIndicator())
            : !_connected
                ? _buildConnectPrompt()
                : _buildLibrary(),
      ),
    );
  }

  Widget _buildConnectPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            const Text(
              'Conecta tu cuenta de Spotify para ver las canciones que te '
              'gustan y descargar sus letras.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _connecting ? null : _connect,
              child: _connecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Conectar con Spotify'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibrary() {
    if (_loadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadFirstPage, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }
    if (_songs.isEmpty) {
      return const Center(
        child: Text(
          'Todavía no le diste "me gusta" a ninguna canción en Spotify.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$_total canciones que te gustan',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              if (!_bulkRunning)
                TextButton(onPressed: _downloadAll, child: const Text('Descargar todas')),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
          child: Row(
            children: [
              const Icon(Icons.download_for_offline_rounded,
                  size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Descargar automáticamente lo que te guste',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              Switch(
                value: _autoDownload,
                activeThumbColor: Theme.of(context).colorScheme.primary,
                onChanged: _bulkRunning ? null : _setAutoDownload,
              ),
            ],
          ),
        ),
        if (_bulkRunning)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: _bulkTotal > 0 ? _bulkDone / _bulkTotal : null,
                  backgroundColor: AppTheme.surface,
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _bulkTotal > 0
                          ? '$_bulkDone / $_bulkTotal · $_bulkSkipped ya las tenías, $_bulkNew nuevas'
                          : 'Comprobando tu biblioteca...',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                    TextButton(
                      onPressed: () {
                        // Corta tanto si la arrancamos nosotros como si nos
                        // enganchamos a una que ya estaba corriendo sola.
                        _syncService.requestCancel();
                        setState(() => _bulkCancelled = true);
                      },
                      child: const Text('Cancelar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
              return false;
            },
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: _songs.length + (_nextUrl != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _songs.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                final song = _songs[index];
                return SongCard(song: song, onTap: () => _openSongSheet(song));
              },
            ),
          ),
        ),
      ],
    );
  }
}
