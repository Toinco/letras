import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_http.dart';

/// Login con Spotify usando OAuth 2.0 Authorization Code + PKCE, el flujo
/// recomendado para apps móviles (no requiere guardar un client secret
/// adentro de la app, que no se puede mantener seguro en un APK).
///
/// Usamos un redirect URI con esquema propio
/// (`io.letras.app://spotify-callback`). Spotify sigue permitiendo
/// esquemas custom sin restricción (solo dejó de aceptar `http://` normal,
/// salvo loopback) — confirmado en su blog de seguridad de feb. 2025. El
/// navegador vuelve a la app mediante ese esquema, Android lo entrega a
/// `MainActivity` (ver `onNewIntent`), y de ahí llega a Dart por un
/// EventChannel nativo.
class SpotifyAuthService {
  // Las playlists (propias y colaborativas) necesitan permisos aparte: si
  // te conectaste antes de que existieran, hay que reconectar una vez.
  static const _scope = 'user-library-read playlist-read-private playlist-read-collaborative';
  static const _grantedScopeKey = 'spotify_granted_scope';
  static const _authEndpoint = 'https://accounts.spotify.com/authorize';
  static const _tokenEndpoint = 'https://accounts.spotify.com/api/token';
  static const _redirectUri = 'io.letras.app://spotify-callback';
  static const _redirectChannel = EventChannel('io.letras.app/spotify_redirect');

  static const _clientIdKey = 'spotify_client_id';
  static const _accessTokenKey = 'spotify_access_token';
  static const _refreshTokenKey = 'spotify_refresh_token';
  static const _expiresAtKey = 'spotify_expires_at';

  Future<String> getClientId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_clientIdKey) ?? '';
  }

  Future<void> setClientId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    // El Client ID no tiene espacios ni saltos de línea; si al pegarlo se
    // coló alguno (típico al copiar desde una página web), lo sacamos para
    // no mandarle a Spotify un client_id inválido.
    final clean = id.replaceAll(RegExp(r'\s'), '');
    await prefs.setString(_clientIdKey, clean);
  }

  Future<bool> isConnected() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey) != null;
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_expiresAtKey);
  }

  String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Inicia el login: abre el navegador y espera a que Spotify redirija de
  /// vuelta a la app (esquema propio, capturado nativamente). Tira una
  /// excepción si algo falla o si el usuario cancela.
  Future<void> connect() async {
    final clientId = await getClientId();
    if (clientId.trim().isEmpty) {
      throw Exception('Falta cargar el Client ID de Spotify en Ajustes.');
    }

    final verifier = _randomString(64);
    final challenge = _codeChallenge(verifier);
    final state = _randomString(16);

    final redirectFuture = _redirectChannel.receiveBroadcastStream().first.timeout(
          const Duration(minutes: 5),
          onTimeout: () => throw Exception('Se agotó el tiempo de espera del login.'),
        );

    final authUri = Uri.parse(_authEndpoint).replace(queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': _scope,
      'state': state,
    });

    final opened = await launchUrl(authUri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw Exception('No se pudo abrir el navegador para el login de Spotify.');
    }

    final redirected = await redirectFuture as String;
    final params = Uri.parse(redirected).queryParameters;
    final error = params['error'];
    final returnedState = params['state'];
    final code = params['code'];

    if (error != null) {
      throw Exception('Spotify canceló el login ($error).');
    }
    if (returnedState != state || code == null) {
      throw Exception('Respuesta de login de Spotify inválida.');
    }

    await _exchangeCode(code: code, verifier: verifier, clientId: clientId);
  }

  Future<void> _exchangeCode({
    required String code,
    required String verifier,
    required String clientId,
  }) async {
    final response = await AppHttp.post(
          Uri.parse(_tokenEndpoint),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': _redirectUri,
            'client_id': clientId,
            'code_verifier': verifier,
          },
          timeout: const Duration(seconds: 10),
        );

    if (response.statusCode != 200) {
      throw Exception('Spotify rechazó el login (${response.statusCode}).');
    }
    await _saveTokens(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> _saveTokens(Map<String, dynamic> json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, json['access_token'] as String);
    if (json['refresh_token'] != null) {
      await prefs.setString(_refreshTokenKey, json['refresh_token'] as String);
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    // Le restamos un margen de 60s para renovar un poco antes de que
    // venza de verdad.
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));
    await prefs.setInt(_expiresAtKey, expiresAt.millisecondsSinceEpoch);
    if (json['scope'] is String) await prefs.setString(_grantedScopeKey, json['scope'] as String);
  }

  /// ¿La sesión actual tiene permiso para leer playlists?
  Future<bool> canReadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_grantedScopeKey) ?? '').contains('playlist-read-private');
  }

  /// Devuelve un access token válido, renovándolo antes si hace falta.
  Future<String> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAtMs = prefs.getInt(_expiresAtKey);
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);

    if (refreshToken == null) {
      throw Exception('No estás conectado a Spotify.');
    }

    final expired = expiresAtMs == null ||
        DateTime.now().isAfter(DateTime.fromMillisecondsSinceEpoch(expiresAtMs));

    if (!expired && accessToken != null) return accessToken;

    final clientId = await getClientId();
    final response = await AppHttp.post(
          Uri.parse(_tokenEndpoint),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'client_id': clientId,
          },
          timeout: const Duration(seconds: 10),
        );

    if (response.statusCode != 200) {
      await disconnect();
      throw Exception('Se venció la sesión de Spotify. Reconecta tu cuenta en Ajustes.');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    await _saveTokens(json);
    return json['access_token'] as String;
  }
}
