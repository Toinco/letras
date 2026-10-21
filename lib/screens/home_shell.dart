import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/favorites_sync_service.dart';
import '../services/spotify_playlist_sync.dart';
import 'downloads_screen.dart';
import 'now_playing_screen.dart';
import 'search_screen.dart';

/// Contenedor con la barra de navegación inferior, con solo 3 secciones
/// (Reproduciendo / Buscar / Descargas), estilo minimalista. Ajustes se
/// abre desde el ícono de tuerca en la pestaña Buscar, y Favoritos
/// (Spotify) vive adentro de Ajustes como una sección propia.
///
/// Cada pestaña se arma recién la primera vez que se visita (en vez de
/// las 3 de una al abrir la app), para que el arranque sea más rápido.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  /// Pestaña visible ahora mismo (0 = Reproduciendo). Las pantallas viven
  /// todas a la vez dentro de un IndexedStack, así que las que necesitan
  /// saber si están en pantalla (ej. para mantenerla encendida) escuchan esto.
  static final ValueNotifier<int> currentTab = ValueNotifier(0);

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  final Set<int> _visited = {0};

  static const _builders = <Widget Function()>[
    NowPlayingScreen.new,
    SearchScreen.new,
    DownloadsScreen.new,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Arranca ya lo de "Reproduciendo" (detección, letra fuera de la app...)
    // aunque la primera pestaña que se vea sea otra.
    ref.read(nowPlayingControllerProvider);
    // Sincroniza "me gusta" de Spotify apenas se abre la app, sin
    // necesidad de entrar a Favoritos — funciona mientras la app está
    // abierta, sin importar en qué pestaña estés.
    FavoritesSyncService().syncIfEnabled();
    // Y las playlists de Spotify marcadas como "automático".
    SpotifyPlaylistSync().syncAuto();
  }

  // Y también cada vez que vuelves a la app (por ejemplo, después de darle
  // "me gusta" a algo en Spotify y volver a Letras).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      FavoritesSyncService().syncIfEnabled();
      SpotifyPlaylistSync().syncAuto();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _select(int i) {
    setState(() {
      _index = i;
      _visited.add(i);
    });
    HomeShell.currentTab.value = i;
  }

  bool _immersive = false;

  /// En horizontal, en Reproduciendo, se esconden la barra de abajo y las
  /// barras del sistema para que la letra tenga toda la pantalla.
  void _syncImmersive(bool hideChrome) {
    if (hideChrome == _immersive) return;
    _immersive = hideChrome;
    SystemChrome.setEnabledSystemUIMode(
      hideChrome ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final hideChrome = landscape && _index == 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncImmersive(hideChrome));
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _builders.length; i++)
            _visited.contains(i) ? _builders[i]() : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: hideChrome
          ? null
          : BottomNavigationBar(
              currentIndex: _index,
              onTap: _select,
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.graphic_eq_rounded),
                  label: 'Reproduciendo',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.search_rounded),
                  label: 'Buscar',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.download_rounded),
                  label: 'Descargas',
                ),
              ],
            ),
    );
  }
}
