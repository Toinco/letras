import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme/app_theme.dart';
import '../utils/platform.dart';
import '../widgets/app_nav_bar.dart';
import '../widgets/desktop.dart';
import '../widgets/update_prompt.dart';
import '../services/favorites_sync_service.dart';
import '../services/spotify_playlist_sync.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_host.dart';
import 'downloads_screen.dart';
import 'home_screen.dart';
import 'now_playing_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// Contenedor con la barra de navegación inferior: Inicio / Reproduciendo /
/// Buscar / Descargas. Ajustes se abre desde la tuerca (en Inicio y Buscar),
/// y Favoritos (Spotify) vive adentro de Ajustes como una sección propia.
///
/// En las pestañas que no son Reproduciendo queda abajo el mini
/// reproductor con lo que suena, como en Apple Music y Spotify.
///
/// Cada pestaña se arma recién la primera vez que se visita (en vez de
/// las 3 de una al abrir la app), para que el arranque sea más rápido.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  static const homeTab = 0;
  static const nowPlayingTab = 1;

  /// Pestaña visible ahora mismo. Las pantallas viven todas a la vez dentro
  /// de un IndexedStack, así que las que necesitan saber si están en
  /// pantalla (ej. para mantenerla encendida) escuchan esto.
  static final ValueNotifier<int> currentTab = ValueNotifier(homeTab);

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  int _index = HomeShell.homeTab;
  final Set<int> _visited = {HomeShell.homeTab};
  bool _userChoseTab = false;

  static const _builders = <Widget Function()>[
    HomeScreen.new,
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
    // Si hay una versión nueva, la ofrece con un botón para instalarla.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdatePrompt.checkOnStartup(context);
    });
    _openNowPlayingIfPlaying();
    requestedTab.addListener(_onTabRequested);
  }

  /// El mini reproductor (desde cualquier pantalla) pide ir a una pestaña.
  void _onTabRequested() {
    final tab = requestedTab.value;
    if (tab == null) return;
    requestedTab.value = null;
    _select(tab);
  }

  /// Si al abrir la app ya está sonando algo, arranca en Reproduciendo (con
  /// la letra); si no, en Inicio. Se mira solo durante los primeros dos
  /// segundos (lo que tarda en detectarse lo que suena).
  Timer? _autoOpenTimer;

  void _openNowPlayingIfPlaying() {
    final c = ref.read(nowPlayingControllerProvider);
    c.addListener(_autoOpenListener);
    _autoOpenTimer = Timer(const Duration(seconds: 2), _stopAutoOpen);
    _autoOpenListener();
  }

  void _autoOpenListener() {
    if (!mounted || _userChoseTab) return _stopAutoOpen();
    if (ref.read(nowPlayingControllerProvider).track?.isPlaying ?? false) {
      _stopAutoOpen();
      _select(HomeShell.nowPlayingTab, byUser: false);
    }
  }

  void _stopAutoOpen() {
    _autoOpenTimer?.cancel();
    _autoOpenTimer = null;
    ref.read(nowPlayingControllerProvider).removeListener(_autoOpenListener);
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
    _autoOpenTimer?.cancel();
    requestedTab.removeListener(_onTabRequested);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _select(int i, {bool byUser = true}) {
    if (byUser) _userChoseTab = true;
    if (i != HomeShell.nowPlayingTab) NowPlayingScreen.immersive.value = false;
    setState(() {
      _index = i;
      _visited.add(i);
    });
    HomeShell.currentTab.value = i;
    visibleTab.value = i;
  }

  bool _immersive = false;
  final _pagesKey = GlobalKey();

  /// En horizontal, en Reproduciendo, se esconden la barra de abajo y las
  /// barras del sistema para que la letra tenga toda la pantalla.
  void _syncImmersive(bool hideChrome) {
    if (hideChrome == _immersive) return;
    _immersive = hideChrome;
    SystemChrome.setEnabledSystemUIMode(
      hideChrome ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  static const _destinations = [
    (icon: Icons.home_rounded, label: 'Inicio'),
    (icon: Icons.graphic_eq_rounded, label: 'Reproduciendo'),
    (icon: Icons.search_rounded, label: 'Buscar'),
    (icon: Icons.download_rounded, label: 'Descargas'),
  ];

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );

  void _onShortcut(String id) {
    final c = ref.read(nowPlayingControllerProvider);
    switch (id) {
      case 'playPause':
        if (c.track != null && !c.track!.fromMicrophone) c.togglePlayPause();
      case 'next':
        c.skipNext();
      case 'previous':
        c.skipPrevious();
      case 'translate':
        if (c.lyrics?.hasSyncedLyrics ?? false) c.toggleTranslation();
      case 'settings':
        _openSettings();
      case 'immersive':
        // Solo con algo sonando y en una ventana ancha.
        if (c.track != null && isWideLayout(context)) {
          _select(HomeShell.nowPlayingTab);
          NowPlayingScreen.immersive.value = !NowPlayingScreen.immersive.value;
        }
      case 'tab0':
        _select(0);
      case 'tab1':
        _select(1);
      case 'tab2':
        _select(2);
      case 'tab3':
        _select(3);
    }
  }

  /// Atajos de teclado (en la Mac con ⌘, en otras compus con Ctrl).
  Map<ShortcutActivator, Intent> get _shortcuts {
    SingleActivator cmd(LogicalKeyboardKey key) =>
        SingleActivator(key, meta: isMac, control: !isMac);
    return {
      const SingleActivator(LogicalKeyboardKey.space): const _ShellIntent('playPause'),
      cmd(LogicalKeyboardKey.arrowRight): const _ShellIntent('next'),
      cmd(LogicalKeyboardKey.arrowLeft): const _ShellIntent('previous'),
      cmd(LogicalKeyboardKey.keyT): const _ShellIntent('translate'),
      cmd(LogicalKeyboardKey.comma): const _ShellIntent('settings'),
      cmd(LogicalKeyboardKey.digit1): const _ShellIntent('tab0'),
      cmd(LogicalKeyboardKey.digit2): const _ShellIntent('tab1'),
      cmd(LogicalKeyboardKey.digit3): const _ShellIntent('tab2'),
      cmd(LogicalKeyboardKey.digit4): const _ShellIntent('tab3'),
      cmd(LogicalKeyboardKey.keyF): const _ShellIntent('tab2'),
      SingleActivator(LogicalKeyboardKey.keyF, meta: isMac, control: !isMac, shift: true):
          const _ShellIntent('immersive'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // En la compu una ventana ancha no es "el teléfono acostado": la barra queda.
    final hideChrome = landscape && _index == HomeShell.nowPlayingTab && !isDesktop && !wide;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncImmersive(hideChrome));
    final pages = IndexedStack(
      // Con clave global: al entrar o salir de pantalla completa (o pasar de
      // barra abajo a menú lateral) las pestañas no se rearman de cero.
      key: _pagesKey,
      index: _index,
      children: [
        for (var i = 0; i < _builders.length; i++)
          _visited.contains(i) ? _builders[i]() : const SizedBox.shrink(),
      ],
    );
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: {_ShellIntent: _ShellAction(_onShortcut)},
        child: Focus(
          autofocus: true,
          child: ValueListenableBuilder<bool>(
            valueListenable: NowPlayingScreen.immersive,
            // En pantalla completa (Reproduciendo) no va el menú lateral.
            builder: (context, immersive, _) => immersive && _index == HomeShell.nowPlayingTab
                ? pages
                : wide
                    ? _buildWide(pages)
                    : _buildNarrow(pages, hideChrome),
          ),
        ),
      ),
    );
  }

  Widget _buildNarrow(Widget pages, bool hideChrome) {
    return Scaffold(
      // En Reproduciendo la carátula difuminada sigue por detrás de la barra,
      // e Inicio deja su propio espacio abajo. Las otras pestañas terminan
      // arriba de la barra (y del mini reproductor).
      extendBody: _index == HomeShell.nowPlayingTab || _index == HomeShell.homeTab,
      body: pages,
      bottomNavigationBar: hideChrome
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_index != HomeShell.nowPlayingTab)
                  MiniPlayer(onOpen: () => _select(HomeShell.nowPlayingTab)),
                AppNavBar(
                  destinations: _destinations,
                  currentIndex: _index,
                  onSelected: _select,
                ),
              ],
            ),
    );
  }

  /// Ventana ancha (Mac, tablet): menú lateral angosto a la izquierda.
  Widget _buildWide(Widget pages) {
    return Scaffold(
      body: Row(
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              color: AppTheme.sidebar,
              border: Border(right: BorderSide(color: Colors.white10)),
            ),
            child: SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -0.85,
                leading: const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 10),
                  child: _AppMark(),
                ),
                trailing: Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: IconButton(
                        tooltip: 'Ajustes',
                        icon: const Icon(Icons.settings_rounded, color: AppTheme.textSecondary),
                        onPressed: _openSettings,
                      ),
                    ),
                  ),
                ),
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
                ],
              ),
            ),
          ),
          Expanded(
            // El mini reproductor flota encima (lo pone PlayerHost), sin
            // franja negra debajo.
            child: pages,
          ),
        ],
      ),
    );
  }
}

/// Logo chico arriba del menú lateral: el mismo dibujo del ícono (tres
/// renglones, el del medio "cantándose"), hecho con widgets.
class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    Widget bar(double width, {double fill = 0, double alpha = 0.55}) => Container(
          width: width,
          height: 5,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: LinearGradient(
              colors: [Colors.white, Colors.white, Colors.white.withValues(alpha: alpha)],
              stops: [0, fill, fill],
            ),
          ),
        );
    return Container(
      width: 36,
      height: 36,
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF6B5E), Color(0xFFFC4E54), Color(0xFFE0426A)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(19, alpha: 0.5),
          const SizedBox(height: 3),
          bar(23, fill: 0.55),
          const SizedBox(height: 3),
          bar(15, alpha: 0.35),
        ],
      ),
    );
  }
}

class _ShellIntent extends Intent {
  final String id;

  const _ShellIntent(this.id);
}

/// Los atajos no se roban teclas mientras se escribe: la barra espaciadora
/// en un buscador tiene que escribir un espacio, no pausar la música.
class _ShellAction extends Action<_ShellIntent> {
  final void Function(String id) onInvoke;

  _ShellAction(this.onInvoke);

  static bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  bool isEnabled(_ShellIntent intent) => !(intent.id == 'playPause' && _typing);

  @override
  Object? invoke(_ShellIntent intent) {
    onInvoke(intent.id);
    return null;
  }
}
