import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme/app_theme.dart';
import '../utils/platform.dart';
import '../widgets/desktop.dart';
import '../services/favorites_sync_service.dart';
import '../services/spotify_playlist_sync.dart';
import 'downloads_screen.dart';
import 'now_playing_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

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

  static const _destinations = [
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
      case 'tab0':
        _select(0);
      case 'tab1':
        _select(1);
      case 'tab2':
        _select(2);
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
      cmd(LogicalKeyboardKey.keyF): const _ShellIntent('tab1'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // En la Mac una ventana ancha no es "el teléfono acostado": la barra queda.
    final hideChrome = landscape && _index == 0 && !isMac && !wide;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncImmersive(hideChrome));
    final pages = IndexedStack(
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
          child: wide ? _buildWide(pages) : _buildNarrow(pages, hideChrome),
        ),
      ),
    );
  }

  Widget _buildNarrow(Widget pages, bool hideChrome) {
    return Scaffold(
      body: pages,
      bottomNavigationBar: hideChrome
          ? null
          : BottomNavigationBar(
              currentIndex: _index,
              onTap: _select,
              type: BottomNavigationBarType.fixed,
              items: [
                for (final d in _destinations)
                  BottomNavigationBarItem(icon: Icon(d.icon), label: d.label),
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
          Expanded(child: pages),
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
