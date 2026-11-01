import 'package:flutter/material.dart';

import 'desktop.dart';
import 'mini_player.dart';

/// Navegador principal de la app (para volver al inicio desde el mini
/// reproductor, esté donde esté).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Pestaña a la que hay que ir (la pide el mini reproductor; la escucha
/// HomeShell).
final ValueNotifier<int?> requestedTab = ValueNotifier(null);

/// Pestaña visible y si Reproduciendo está en pantalla completa (los
/// actualiza HomeShell), para saber si mostrar el mini reproductor.
final ValueNotifier<int> visibleTab = ValueNotifier(0);
const int nowPlayingTabIndex = 1;

/// Cuántas pantallas hay abiertas encima de la principal (un álbum, un
/// artista, Ajustes...). Solo cuenta pantallas, no hojas ni diálogos.
class PageCounter extends NavigatorObserver {
  static final ValueNotifier<int> pushed = ValueNotifier(0);
  final List<Route<dynamic>> _pages = [];

  void _sync() => pushed.value = (_pages.length - 1).clamp(0, 999);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _pages.add(route);
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (i >= 0) _pages.removeAt(i);
    if (newRoute is PageRoute) _pages.insert(i >= 0 ? i : _pages.length, newRoute);
    _sync();
  }
}

/// Abre Reproduciendo desde cualquier lado.
void openNowPlaying() {
  appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
  requestedTab.value = nowPlayingTabIndex;
}

/// Pone el mini reproductor flotando abajo, por encima de todas las
/// pantallas (como en Apple Music y Spotify): en un álbum, un artista o una
/// lista sigue a mano. En el teléfono, en la pantalla principal lo pone la
/// propia barra de abajo, así que acá solo aparece en las pantallas
/// abiertas encima.
class PlayerHost extends StatelessWidget {
  final Widget child;

  const PlayerHost({super.key, required this.child});

  /// Ancho del menú lateral en pantallas anchas (el mini reproductor se
  /// centra en el contenido, no en toda la ventana).
  static const railWidth = 85.0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PageCounter.pushed,
      builder: (context, pushed, _) => ValueListenableBuilder<int>(
        valueListenable: visibleTab,
        builder: (context, tab, _) {
          final wide = isWideLayout(context);
          final onShell = pushed == 0;
          final show = onShell ? (wide && tab != nowPlayingTabIndex) : true;
          if (!show) return child;
          final bottom = MediaQuery.paddingOf(context).bottom;
          return Stack(
            children: [
              child,
              Positioned(
                left: onShell ? railWidth : 0,
                right: 0,
                bottom: 8 + bottom,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    // Overlay propio: los botones tienen tooltips, y acá
                    // estamos por fuera del navegador.
                    child: SizedBox(
                      height: 66,
                      child: Overlay(
                        initialEntries: [
                          OverlayEntry(
                            builder: (_) => const Align(
                              alignment: Alignment.bottomCenter,
                              child: MiniPlayer(onOpen: openNowPlaying),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
