import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/now_playing_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../widgets/update_prompt.dart';
import '../theme/app_theme.dart';
import 'error_log_screen.dart';
import 'favorites_screen.dart';
import 'spotify_playlists_screen.dart';
import 'stats_screen.dart';
import '../providers.dart';
import '../utils/platform.dart';
import '../widgets/desktop.dart';

/// Ajustes de la app, por secciones: cómo se ve la letra, traducción,
/// letra fuera de la app, detección, fuentes, cuentas y "acerca de".
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with WidgetsBindingObserver {
  late final _settingsService = ref.read(settingsProvider);
  late final _nowPlayingService = ref.read(nowPlayingServiceProvider);
  late final _spotifyAuth = ref.read(spotifyAuthProvider);
  final _tokenController = TextEditingController();
  final _spotifyClientIdController = TextEditingController();
  final _geniusTokenController = TextEditingController();
  final _claudeKeyController = TextEditingController();

  bool _accessGranted = false;
  bool _spotifyConnected = false;
  bool _autoSaveListened = false;
  bool _canDrawOverlays = false;
  bool _hasWidgets = false;
  String _version = '';
  bool _checkingUpdate = false;

  static const _languages = {
    'es': 'Español',
    'en': 'Inglés',
    'pt': 'Portugués',
    'fr': 'Francés',
    'it': 'Italiano',
    'de': 'Alemán',
    'ja': 'Japonés',
    'ko': 'Coreano',
    'zh-CN': 'Chino',
    'ru': 'Ruso',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  // Los permisos (notificaciones, superposición) se dan en Ajustes de
  // Android: hay que revisarlos cuando se vuelve a la app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final token = await _settingsService.getAudDToken();
    final granted = await _nowPlayingService.isNotificationAccessGranted();
    final spotifyClientId = await _spotifyAuth.getClientId();
    final spotifyConnected = await _spotifyAuth.isConnected();
    final geniusToken = await _settingsService.getGeniusToken();
    final claudeKey = await _settingsService.getClaudeApiKey();
    final autoSave = await _settingsService.getAutoSaveListened();
    final overlays = await _nowPlayingService.canDrawOverlays();
    final widgets = await _nowPlayingService.hasHomeWidgets();
    String version = '';
    try {
      version = await UpdateService().currentVersion();
    } catch (_) {}
    await SettingsService.reloadOutsideOptions();
    if (mounted) {
      setState(() {
        _autoSaveListened = autoSave;
        _tokenController.text = token;
        _accessGranted = granted;
        _spotifyClientIdController.text = spotifyClientId;
        _spotifyConnected = spotifyConnected;
        _geniusTokenController.text = geniusToken;
        _claudeKeyController.text = claudeKey;
        _canDrawOverlays = overlays;
        _hasWidgets = widgets;
        _version = version;
      });
    }
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveToken() async {
    await _settingsService.setAudDToken(_tokenController.text);
    _snack('API token guardado.');
  }

  Future<void> _saveGeniusToken() async {
    await _settingsService.setGeniusToken(_geniusTokenController.text);
    _snack('Token de Genius guardado.');
  }

  Future<void> _saveClaudeKey() async {
    await _settingsService.setClaudeApiKey(_claudeKeyController.text);
    _snack('API key de Anthropic guardada (solo en este dispositivo).');
  }

  Future<void> _saveSpotifyClientId() async {
    await _spotifyAuth.setClientId(_spotifyClientIdController.text);
    _snack('Client ID de Spotify guardado.');
  }

  Future<void> _disconnectSpotify() async {
    await _spotifyAuth.disconnect();
    if (mounted) setState(() => _spotifyConnected = false);
  }

  /// La notificación con la letra necesita permiso de notificaciones en
  /// Android 13 o más nuevo.
  Future<void> _setLiveNotification(bool value) async {
    if (value && !isDesktop) {
      final status = await Permission.notification.request();
      if (!status.isGranted) {
        _snack('Sin permiso de notificaciones no se puede mostrar la letra ahí.');
        if (status.isPermanentlyDenied) await openAppSettings();
        return;
      }
    }
    await _settingsService.setLiveNotification(value);
  }

  /// La burbuja necesita el permiso "Mostrar sobre otras apps".
  Future<void> _setBubble(bool value) async {
    if (value && !_canDrawOverlays) {
      _snack('Activa "Mostrar sobre otras apps" para Letras y vuelve.');
      await _nowPlayingService.openOverlaySettings();
    }
    if (value) await Permission.notification.request();
    await _settingsService.setFloatingBubble(value);
  }

  Future<void> _checkForUpdates() async {
    setState(() => _checkingUpdate = true);
    try {
      final release = await UpdateService().checkForUpdate();
      UpdatePrompt.available.value = release;
      if (!mounted) return;
      if (release == null) {
        _snack('Ya tienes la última versión.');
        return;
      }
      if (await UpdatePrompt.confirm(context, release) != true || !mounted) return;
      await UpdatePrompt.install(context, release);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _resetAppOffset(String pkg) async {
    await _settingsService.setAppOffset(pkg, Duration.zero);
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tokenController.dispose();
    _spotifyClientIdController.dispose();
    _geniusTokenController.dispose();
    _claudeKeyController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- UI

  Widget _section(String title) => _SectionTitle(title);

  /// Lo que viene después de cada título va en una tarjeta propia, como los
  /// grupos de Ajustes del iPhone (antes era todo una sola lista plana).
  List<Widget> _grouped(List<Widget> children) {
    final out = <Widget>[];
    List<Widget>? group;
    void close() {
      if (group != null && group!.isNotEmpty) out.add(_SettingsCard(children: group!));
      group = null;
    }

    for (final w in children) {
      if (w is _SectionTitle) {
        close();
        out.add(w);
        group = [];
      } else if (group != null) {
        group!.add(w);
      } else {
        out.add(w);
      }
    }
    close();
    return out;
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(text, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );

  Widget _switch({
    required ValueNotifier<bool> notifier,
    required String title,
    String? subtitle,
    required ValueChanged<bool> onChanged,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, value, _) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: const TextStyle(color: AppTheme.textSecondary)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget _tokenField(TextEditingController c, String hint, VoidCallback onSave,
      {bool obscure = false}) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: c,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(onPressed: onSave, child: const Text('Guardar')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ReadableFrame(
      child: Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          children: _grouped([
            // ------------------------------------------------ Letra
            _section('Letra'),
            ValueListenableBuilder<double>(
              valueListenable: SettingsService.fontScale,
              builder: (context, scale, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.text_fields_rounded, size: 18, color: AppTheme.textSecondary),
                      Expanded(
                        child: Slider(
                          value: scale,
                          min: 0.75,
                          max: 1.4,
                          divisions: 13,
                          label: '${(scale * 100).round()}%',
                          onChanged: (v) => _settingsService.setFontScale(v),
                        ),
                      ),
                      const Icon(Icons.text_fields_rounded, size: 28, color: AppTheme.textSecondary),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'Así se ve la letra',
                      style: TextStyle(fontSize: 27 * scale, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            _switch(
              notifier: SettingsService.karaokeFill,
              title: 'Efecto karaoke',
              subtitle: 'Si la letra trae el tiempo de cada palabra, se van iluminando '
                  'mientras se cantan.',
              onChanged: _settingsService.setKaraokeFill,
            ),
            _switch(
              notifier: SettingsService.splitBackgroundVocals,
              title: 'Coros más chicos y a la derecha',
              subtitle: 'Lo que va entre paréntesis se muestra aparte, como en Apple Music.',
              onChanged: _settingsService.setSplitBackgroundVocals,
            ),
            _switch(
              notifier: SettingsService.blurDistantLines,
              title: 'Desenfocar las líneas lejanas',
              onChanged: _settingsService.setBlurDistantLines,
            ),
            _switch(
              notifier: SettingsService.dynamicAccent,
              title: 'Color según la carátula',
              subtitle: 'El color de la app sale de la carátula de lo que suena.',
              onChanged: _settingsService.setDynamicAccent,
            ),
            _switch(
              notifier: SettingsService.keepScreenOn,
              title: 'Mantener la pantalla encendida',
              subtitle: 'Mientras estás viendo la letra de algo que suena.',
              onChanged: _settingsService.setKeepScreenOn,
            ),

            // ------------------------------------------------ Traducción
            _section('Traducción y pronunciación'),
            ValueListenableBuilder<String>(
              valueListenable: SettingsService.translationLang,
              builder: (context, lang, _) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Traducir al'),
                trailing: DropdownButton<String>(
                  value: _languages.containsKey(lang) ? lang : 'es',
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final e in _languages.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => v == null ? null : _settingsService.setTranslationLang(v),
                ),
              ),
            ),
            _switch(
              notifier: SettingsService.showRomanization,
              title: 'Mostrar la pronunciación',
              subtitle: 'En letras en japonés, coreano, ruso, chino, etc., la lectura en '
                  'letras latinas debajo de cada línea.',
              onChanged: _settingsService.setShowRomanization,
            ),
            _switch(
              notifier: SettingsService.aiTranslation,
              title: 'Traducir con IA (Claude)',
              subtitle: 'Entiende jerga y dobles sentidos. Usa tu API key de Anthropic '
                  '(cada canción cuesta unos centavos de dólar).',
              onChanged: _settingsService.setAiTranslation,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: SettingsService.aiTranslation,
              builder: (context, ai, _) => !ai
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _hint('Crea una key en console.anthropic.com > API Keys y pégala aquí. '
                            'Queda guardada solo en este dispositivo. Si falla, se usa el '
                            'traductor común.'),
                        _tokenField(_claudeKeyController, 'sk-ant-...', _saveClaudeKey,
                            obscure: true),
                      ],
                    ),
            ),

            // ------------------------------------------------ Fuera de la app
            // En Windows todavía no hay dónde mostrarla fuera de la ventana.
            if (!isWindows) _section('Letra fuera de la app'),
            if (isMac)
              _switch(
                notifier: SettingsService.liveNotification,
                title: 'Letra en la barra de menú',
                subtitle: 'La línea que se está cantando aparece arriba, junto al reloj. '
                    'Un clic abre Letras.',
                onChanged: _setLiveNotification,
              )
            else if (!isWindows) ...[
              _switch(
                notifier: SettingsService.liveNotification,
                title: 'Notificación con la línea actual',
                subtitle: 'Ves lo que se está cantando sin abrir la app (también en la '
                    'pantalla de bloqueo). Necesario para el widget.',
                onChanged: _setLiveNotification,
              ),
              _switch(
                notifier: SettingsService.floatingBubble,
                title: 'Burbuja flotante',
                subtitle: _canDrawOverlays
                    ? 'La letra flota encima de Spotify u otras apps. Arrástrala para '
                        'moverla; un toque la achica.'
                    : 'Necesita el permiso "Mostrar sobre otras apps".',
                onChanged: _setBubble,
              ),
              _hint(_hasWidgets
                  ? 'Tienes el widget "Letra actual" en la pantalla de inicio.'
                  : 'Widget: mantén apretado el fondo de la pantalla de inicio > Widgets > '
                      'Letras > "Letra actual". Se actualiza mientras esté prendida la '
                      'notificación o la burbuja.'),
            ],

            // ------------------------------------------------ Detección
            _section('Detección y reproducción'),
            Text(
              isWindows
                  ? 'Letras detecta lo que suena en Spotify, en el navegador y en cualquier app '
                      'que muestre sus controles en Windows (el cuadro que aparece al subir el '
                      'volumen). No hace falta ningún permiso.'
                  : isMac
                      ? 'Letras detecta lo que suena en Spotify y en Música. Si no detecta nada, '
                          'revisa que Letras tenga permiso en Ajustes del Sistema > Privacidad '
                          'y seguridad > Automatización.'
                      : _accessGranted
                          ? 'Acceso a notificaciones concedido: la app detecta lo que escuchas.'
                          : 'Acceso a notificaciones no concedido: actívalo para detectar la '
                              'música.',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            if (!isWindows)
              OutlinedButton(
                onPressed: () async {
                  await _nowPlayingService.openNotificationAccessSettings();
                  _load();
                },
                child: Text(isMac
                    ? 'Abrir Automatización'
                    : _accessGranted
                        ? 'Abrir ajustes'
                        : 'Dar acceso'),
              ),
            _switch(
              notifier: SettingsService.prefetchNext,
              title: 'Buscar por adelantado la próxima canción',
              subtitle: 'Si la app de música informa la cola, la letra de la siguiente '
                  'ya está lista cuando empieza.',
              onChanged: _settingsService.setPrefetchNext,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Guardar sola lo que escucho'),
              subtitle: const Text(
                'Cada canción que suena en "Reproduciendo" se descarga sola, con '
                'traducción, para verla sin conexión.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              value: _autoSaveListened,
              onChanged: (v) async {
                setState(() => _autoSaveListened = v);
                await _settingsService.setAutoSaveListened(v);
              },
            ),
            ValueListenableBuilder<String?>(
              valueListenable: SettingsService.preferredPackage,
              builder: (context, pkg, _) => pkg == null
                  ? const SizedBox.shrink()
                  : ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('App que se sigue'),
                      subtitle: Text(NowPlayingTrack.appName(pkg) ?? pkg),
                      trailing: TextButton(
                        onPressed: () => _settingsService.setPreferredPackage(null),
                        child: const Text('Automático'),
                      ),
                    ),
            ),
            ValueListenableBuilder<Map<String, int>>(
              valueListenable: SettingsService.appOffsets,
              builder: (context, offsets, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (offsets.isNotEmpty) _hint('Desfase general por app:'),
                  for (final e in offsets.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(NowPlayingTrack.appName(e.key) ?? e.key),
                      subtitle: Text(
                        '${e.value > 0 ? '+' : ''}${(e.value / 1000).toStringAsFixed(2)} s',
                      ),
                      trailing: IconButton(
                        tooltip: 'Quitar',
                        icon: const Icon(Icons.restart_alt_rounded),
                        onPressed: () => _resetAppOffset(e.key),
                      ),
                    ),
                  if (offsets.isEmpty)
                    _hint('Si usas auriculares Bluetooth con retraso, en Reproduciendo > '
                        'ajustar sincronización puedes corregirlo para toda una app.'),
                ],
              ),
            ),

            // ------------------------------------------------ Fuentes
            _section('Fuentes de letras'),
            _switch(
              notifier: SettingsService.extraSources,
              title: 'Buscar también en NetEase y Genius',
              subtitle: 'Cuando LRCLIB no tiene la letra: NetEase (sincronizada, mucho '
                  'catálogo asiático) y Genius (sin sincronizar).',
              onChanged: _settingsService.setExtraSources,
            ),

            // ------------------------------------------------ Micrófono / Genius
            _section('Reconocimiento por micrófono (AudD)'),
            _hint('Para reconocer canciones con el micrófono (tipo Shazam). Saca un token '
                'gratis en audd.io y pégalo aquí.'),
            _tokenField(_tokenController, 'Pega tu API token', _saveToken),

            _section('Genius (sección "Info")'),
            _hint('Para la sección "Info" de cada letra (de qué habla, quién la escribió). '
                'Genera un "Client Access Token" en genius.com/api-clients.'),
            _tokenField(_geniusTokenController, 'Client Access Token', _saveGeniusToken),

            // ------------------------------------------------ Spotify
            _section('Spotify'),
            _hint('Para tus "Canciones que te gustan" y tus playlists: crea una app gratis '
                'en developer.spotify.com/dashboard y pega aquí su Client ID. El Redirect '
                'URI exacto es:\nio.letras.app://spotify-callback'),
            _tokenField(_spotifyClientIdController, 'Client ID de Spotify', _saveSpotifyClientId),
            const SizedBox(height: 8),
            Text(
              _spotifyConnected ? 'Cuenta de Spotify conectada.' : 'Todavía no conectaste Spotify.',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.favorite_rounded, color: Theme.of(context).colorScheme.primary),
              label: const Text('Favoritos: canciones que te gustan'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FavoritesScreen()),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.queue_music_rounded),
              label: const Text('Tus playlists'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SpotifyPlaylistsScreen()),
              ),
            ),
            if (_spotifyConnected) ...[
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _disconnectSpotify, child: const Text('Desconectar Spotify')),
            ],

            // ------------------------------------------------ Acerca de
            _section('Acerca de'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insights_rounded),
              title: const Text('Estadísticas de escucha'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StatsScreen()),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_rounded),
              title: const Text('Registro de errores'),
              subtitle: const Text('Para mandar si algo anda mal',
                  style: TextStyle(color: AppTheme.textSecondary)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ErrorLogScreen()),
              ),
            ),
            if (UpdateService.isConfigured)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _checkingUpdate
                    ? const SizedBox(
                        width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.system_update_rounded),
                title: ValueListenableBuilder<AppRelease?>(
                  valueListenable: UpdatePrompt.available,
                  builder: (context, release, _) => Text(release == null
                      ? 'Buscar actualizaciones'
                      : 'Actualizar a la versión ${release.version}'),
                ),
                subtitle: Text('Versión $_version',
                    style: const TextStyle(color: AppTheme.textSecondary)),
                trailing: ValueListenableBuilder<AppRelease?>(
                  valueListenable: UpdatePrompt.available,
                  builder: (context, release, _) => release == null
                      ? const SizedBox.shrink()
                      : Icon(Icons.circle, size: 10, color: Theme.of(context).colorScheme.primary),
                ),
                onTap: _checkingUpdate ? null : _checkForUpdates,
              )
            else if (_version.isNotEmpty)
              _hint('Versión $_version'),
          ]),
        ),
      ),
    );
  }
}

/// Título de un grupo de ajustes, con su ícono.
class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  static const _icons = <String, IconData>{
    'Letra': Icons.lyrics_rounded,
    'Traducción y pronunciación': Icons.translate_rounded,
    'Letra fuera de la app': Icons.picture_in_picture_alt_rounded,
    'Detección y reproducción': Icons.graphic_eq_rounded,
    'Fuentes de letras': Icons.library_books_rounded,
    'Reconocimiento por micrófono (AudD)': Icons.mic_rounded,
    'Genius (sección "Info")': Icons.info_rounded,
    'Spotify': Icons.queue_music_rounded,
    'Acerca de': Icons.favorite_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 10, left: 4),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_icons[title] ?? Icons.tune_rounded, size: 15, color: accent),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: -0.1),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta que agrupa los ajustes de una sección.
class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}
