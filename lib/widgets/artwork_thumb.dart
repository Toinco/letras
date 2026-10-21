import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../providers.dart';

/// Muestra la carátula de una canción, en orden de prioridad:
/// 1. [bytes] si vienen directo (ej. la carátula real de la sesión multimedia).
/// 2. Carátula guardada localmente, si esta canción está descargada (así
///    funciona sin conexión).
/// 3. [imageUrl] si ya la conocemos (ej. viene de Spotify).
/// 4. Si no, busca una carátula por título/artista en iTunes.
/// Si no encuentra nada, muestra un ícono de música como respaldo.
class ArtworkThumb extends ConsumerStatefulWidget {
  final String title;
  final String artist;
  final double size;
  final double borderRadius;
  final Uint8List? bytes;
  final String? imageUrl;

  const ArtworkThumb({
    super.key,
    required this.title,
    required this.artist,
    this.size = 52,
    this.borderRadius = 10,
    this.bytes,
    this.imageUrl,
  });

  @override
  ConsumerState<ArtworkThumb> createState() => _ArtworkThumbState();
}

class _ArtworkThumbState extends ConsumerState<ArtworkThumb> {
  late final _artworkService = ref.read(artworkProvider);
  late final _storage = ref.read(storageProvider);
  String? _url;
  Uint8List? _localBytes;

  bool get _needsLookup => widget.bytes == null;

  @override
  void initState() {
    super.initState();
    if (_needsLookup) _load();
  }

  @override
  void didUpdateWidget(covariant ArtworkThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_needsLookup &&
        (oldWidget.title != widget.title || oldWidget.artist != widget.artist)) {
      _url = null;
      _localBytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    // Primero la copia local (si esta canción está descargada): es
    // instantáneo y funciona sin conexión.
    final local = await _storage.getArtworkBytes(widget.title, widget.artist);
    if (local != null) {
      if (mounted) setState(() => _localBytes = local);
      return;
    }
    if (widget.imageUrl != null) return; // ya la tenemos, no hace falta buscar en iTunes
    final url = await _artworkService.fetchArtworkUrl(widget.title, widget.artist);
    if (mounted) setState(() => _url = url);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);

    Widget placeholder() => Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(color: AppTheme.surface, borderRadius: radius),
          child: Icon(
            Icons.music_note_rounded,
            color: AppTheme.textSecondary,
            size: widget.size * 0.4,
          ),
        );

    final memoryBytes = widget.bytes ?? _localBytes;
    if (memoryBytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          memoryBytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => placeholder(),
        ),
      );
    }

    final effectiveUrl = widget.imageUrl ?? _url;
    if (effectiveUrl == null) return placeholder();

    // CachedNetworkImage guarda la imagen en memoria y en disco: si la
    // misma carátula vuelve a aparecer (otra vez en la lista, o al volver
    // a esta pantalla), se muestra al instante en vez de pedirla de nuevo
    // por red. Antes, con Image.network simple, cada reconstrucción del
    // widget volvía a descargarla.
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: effectiveUrl,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        memCacheWidth: (widget.size * 2).round(),
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => placeholder(),
        errorWidget: (_, __, ___) => placeholder(),
      ),
    );
  }
}
