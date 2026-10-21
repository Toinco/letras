import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda ajustes simples de la app (por ahora, el API token de AudD)
/// usando SharedPreferences.
class SettingsService {
  static const _audDTokenKey = 'audd_api_token';
  static const _autoDownloadFavoritesKey = 'spotify_auto_download_favorites';
  static const _geniusTokenKey = 'genius_access_token';
  static const _fontScaleKey = 'lyrics_font_scale';
  static const _keepScreenOnKey = 'keep_screen_on';
  static const _autoSaveListenedKey = 'auto_save_listened';
  static const _karaokeKey = 'karaoke_fill';
  static const _syncOffsetsKey = 'sync_offsets_ms';
  static const _appOffsetsKey = 'app_offsets_ms';
  static const _blurKey = 'blur_distant_lines';
  static const _backgroundVocalsKey = 'split_background_vocals';
  static const _dynamicAccentKey = 'dynamic_accent';
  static const _translationLangKey = 'translation_target_lang';
  static const _romanizeKey = 'show_romanization';
  static const _aiTranslationKey = 'ai_translation';
  static const _claudeKeyKey = 'claude_api_key';
  static const _preferredPackageKey = 'preferred_player_package';
  static const _liveNotificationKey = 'live_notification';
  static const _floatingBubbleKey = 'floating_bubble';
  static const _prefetchNextKey = 'prefetch_next';
  static const _extraSourcesKey = 'extra_lyrics_sources';

  /// Preferencias de visualización que tienen que reflejarse al instante en
  /// todas las pantallas abiertas (tamaño de letra, efecto karaoke...).
  static final ValueNotifier<double> fontScale = ValueNotifier(1.0);
  static final ValueNotifier<bool> karaokeFill = ValueNotifier(true);
  static final ValueNotifier<bool> keepScreenOn = ValueNotifier(true);
  static final ValueNotifier<bool> blurDistantLines = ValueNotifier(true);
  static final ValueNotifier<bool> splitBackgroundVocals = ValueNotifier(true);
  static final ValueNotifier<bool> dynamicAccent = ValueNotifier(true);
  static final ValueNotifier<bool> showRomanization = ValueNotifier(false);

  /// Idioma al que se traduce (código ISO 639-1: es, en, pt, fr...).
  static final ValueNotifier<String> translationLang = ValueNotifier('es');

  /// Traducir con Claude en vez de Google (necesita API key de Anthropic).
  static final ValueNotifier<bool> aiTranslation = ValueNotifier(false);

  /// App de música a seguir cuando suenan dos a la vez (null = automático).
  static final ValueNotifier<String?> preferredPackage = ValueNotifier(null);

  /// Notificación fija con la línea actual (y widget de inicio).
  static final ValueNotifier<bool> liveNotification = ValueNotifier(false);

  /// Burbuja flotante con la letra encima de otras apps.
  static final ValueNotifier<bool> floatingBubble = ValueNotifier(false);

  /// Buscar por adelantado la letra de la próxima canción de la cola.
  static final ValueNotifier<bool> prefetchNext = ValueNotifier(true);

  /// Buscar en Musixmatch / NetEase / Genius cuando LRCLIB no la tiene.
  static final ValueNotifier<bool> extraSources = ValueNotifier(true);

  /// Desfase general por app de música (paquete -> ms), p. ej. para
  /// auriculares Bluetooth con latencia.
  static final ValueNotifier<Map<String, int>> appOffsets = ValueNotifier(const {});

  /// Carga una vez, al arrancar la app, las preferencias "en vivo".
  static Future<void> loadLivePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    fontScale.value = prefs.getDouble(_fontScaleKey) ?? 1.0;
    karaokeFill.value = prefs.getBool(_karaokeKey) ?? true;
    keepScreenOn.value = prefs.getBool(_keepScreenOnKey) ?? true;
    blurDistantLines.value = prefs.getBool(_blurKey) ?? true;
    splitBackgroundVocals.value = prefs.getBool(_backgroundVocalsKey) ?? true;
    dynamicAccent.value = prefs.getBool(_dynamicAccentKey) ?? true;
    showRomanization.value = prefs.getBool(_romanizeKey) ?? false;
    translationLang.value = prefs.getString(_translationLangKey) ?? 'es';
    aiTranslation.value = prefs.getBool(_aiTranslationKey) ?? false;
    preferredPackage.value = prefs.getString(_preferredPackageKey);
    liveNotification.value = prefs.getBool(_liveNotificationKey) ?? false;
    floatingBubble.value = prefs.getBool(_floatingBubbleKey) ?? false;
    prefetchNext.value = prefs.getBool(_prefetchNextKey) ?? true;
    extraSources.value = prefs.getBool(_extraSourcesKey) ?? true;
    try {
      final raw = jsonDecode(prefs.getString(_appOffsetsKey) ?? '{}') as Map<String, dynamic>;
      appOffsets.value = raw.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      appOffsets.value = const {};
    }
  }

  /// Relee las opciones que se pueden apagar desde afuera de la app (el
  /// botón "Ocultar" de la notificación o la × de la burbuja).
  static Future<void> reloadOutsideOptions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    liveNotification.value = prefs.getBool(_liveNotificationKey) ?? false;
    floatingBubble.value = prefs.getBool(_floatingBubbleKey) ?? false;
  }

  Future<void> _setBool(ValueNotifier<bool> notifier, String key, bool value) async {
    notifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> setBlurDistantLines(bool v) => _setBool(blurDistantLines, _blurKey, v);
  Future<void> setSplitBackgroundVocals(bool v) =>
      _setBool(splitBackgroundVocals, _backgroundVocalsKey, v);
  Future<void> setDynamicAccent(bool v) => _setBool(dynamicAccent, _dynamicAccentKey, v);
  Future<void> setShowRomanization(bool v) => _setBool(showRomanization, _romanizeKey, v);
  Future<void> setAiTranslation(bool v) => _setBool(aiTranslation, _aiTranslationKey, v);
  Future<void> setLiveNotification(bool v) => _setBool(liveNotification, _liveNotificationKey, v);
  Future<void> setFloatingBubble(bool v) => _setBool(floatingBubble, _floatingBubbleKey, v);
  Future<void> setPrefetchNext(bool v) => _setBool(prefetchNext, _prefetchNextKey, v);
  Future<void> setExtraSources(bool v) => _setBool(extraSources, _extraSourcesKey, v);

  Future<void> setTranslationLang(String lang) async {
    translationLang.value = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_translationLangKey, lang);
  }

  Future<void> setPreferredPackage(String? pkg) async {
    preferredPackage.value = pkg;
    final prefs = await SharedPreferences.getInstance();
    if (pkg == null) {
      await prefs.remove(_preferredPackageKey);
    } else {
      await prefs.setString(_preferredPackageKey, pkg);
    }
  }

  /// Desfase general de [package] (se suma al de cada canción).
  static Duration appOffsetFor(String? package) =>
      Duration(milliseconds: package == null ? 0 : (appOffsets.value[package] ?? 0));

  Future<void> setAppOffset(String package, Duration offset) async {
    final map = Map<String, int>.from(appOffsets.value);
    if (offset == Duration.zero) {
      map.remove(package);
    } else {
      map[package] = offset.inMilliseconds;
    }
    appOffsets.value = map;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appOffsetsKey, jsonEncode(map));
  }

  /// API key de Anthropic para la traducción con Claude. Queda solo en
  /// este teléfono.
  Future<String> getClaudeApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_claudeKeyKey) ?? '';
  }

  Future<void> setClaudeApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_claudeKeyKey, key.trim());
  }

  Future<void> setFontScale(double value) async {
    fontScale.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontScaleKey, value);
  }

  Future<void> setKaraokeFill(bool value) async {
    karaokeFill.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_karaokeKey, value);
  }

  Future<void> setKeepScreenOn(bool value) async {
    keepScreenOn.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, value);
  }

  /// Si está prendido, toda canción que suena en "Reproduciendo" y tiene
  /// letra se guarda sola en Descargas (con traducción y carátula), así
  /// lo que escuchas queda disponible sin conexión sin tocar nada.
  Future<bool> getAutoSaveListened() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSaveListenedKey) ?? false;
  }

  Future<void> setAutoSaveListened(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSaveListenedKey, value);
  }

  // --- Desfase de sincronización por canción. Algunas letras de LRCLIB
  // están corridas medio segundo (o vienen de otra versión de la canción):
  // el usuario lo ajusta una vez y queda guardado para esa canción. ---

  static String _offsetKey(String title, String artist) =>
      '${artist.toLowerCase().trim()}|||${title.toLowerCase().trim()}';

  Future<Duration> getSyncOffset(String title, String artist) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_syncOffsetsKey);
    if (raw == null) return Duration.zero;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ms = map[_offsetKey(title, artist)] as int?;
      return Duration(milliseconds: ms ?? 0);
    } catch (_) {
      return Duration.zero;
    }
  }

  Future<void> setSyncOffset(String title, String artist, Duration offset) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> map = {};
    try {
      map = jsonDecode(prefs.getString(_syncOffsetsKey) ?? '{}') as Map<String, dynamic>;
    } catch (_) {}
    final key = _offsetKey(title, artist);
    if (offset == Duration.zero) {
      map.remove(key);
    } else {
      map[key] = offset.inMilliseconds;
    }
    await prefs.setString(_syncOffsetsKey, jsonEncode(map));
  }

  /// Token por defecto para que el reconocimiento por micrófono funcione
  /// sin configuración extra. No está escrito en el código (el repositorio
  /// es público): se pasa al compilar con `--dart-define=AUDD_TOKEN=...`
  /// (en tu computadora sale de `config/dart_defines.json`, que no se sube a git;
  /// en GitHub Actions, del secreto AUDD_TOKEN). Cada usuario puede pisarlo
  /// cargando el suyo propio en Ajustes.
  static const _defaultAudDToken = String.fromEnvironment('AUDD_TOKEN');

  Future<String> getAudDToken() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_audDTokenKey);
    if (saved != null && saved.trim().isNotEmpty) return saved;
    return _defaultAudDToken;
  }

  Future<void> setAudDToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audDTokenKey, token.trim());
  }

  /// Si está prendido, la pestaña Favoritos descarga sola la letra de
  /// cualquier canción nueva que le hayas dado "me gusta" en Spotify,
  /// como el toggle "Descargar" de las Canciones que te gustan en la app
  /// oficial de Spotify. Se revisa cada vez que se abre esa pestaña (la
  /// app no corre en segundo plano, así que no es instantáneo apenas le
  /// das like, sino la próxima vez que abres Letras).
  Future<bool> getAutoDownloadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoDownloadFavoritesKey) ?? false;
  }

  Future<void> setAutoDownloadFavorites(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoDownloadFavoritesKey, value);
  }

  /// Token de Genius (genius.com/api-clients) para la sección "Info" de la
  /// letra: de qué habla la canción, quién la escribió, cuándo salió, etc.
  Future<String> getGeniusToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_geniusTokenKey) ?? '';
  }

  Future<void> setGeniusToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_geniusTokenKey, token.trim());
  }
}
