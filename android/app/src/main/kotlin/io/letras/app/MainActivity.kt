package io.letras.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Puente entre Flutter y Android.
 *
 * El motor de Flutter se guarda en caché a nivel aplicación: si Android
 * cierra la pantalla (por memoria, o porque la sacaste de recientes) pero
 * el proceso sigue vivo gracias a LiveLyricsService, la parte de Flutter
 * sigue corriendo y puede buscar la letra de la próxima canción para la
 * notificación, el widget y la burbuja.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val ENGINE_ID = "main_engine"
        private const val METHOD_CHANNEL = "io.letras.app/now_playing"
        private const val EVENT_CHANNEL = "io.letras.app/now_playing_stream"
        private const val SPOTIFY_CHANNEL = "io.letras.app/spotify_redirect"

        // Login de Spotify: si la redirección llega antes de que Flutter
        // esté escuchando, la guardamos aquí y la emitimos al suscribirse.
        private var spotifyRedirectSink: EventChannel.EventSink? = null
        private var pendingSpotifyRedirect: String? = null
        private var channelsEngine: FlutterEngine? = null
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MediaSessionBridge.init(applicationContext)
        // Con el motor en caché, esto se llama de nuevo cada vez que se
        // recrea la pantalla: los canales se registran una sola vez.
        if (channelsEngine === flutterEngine) return
        channelsEngine = flutterEngine
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val app = applicationContext

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationAccessGranted" -> result.success(MediaSessionBridge.isAccessGranted())
                "openNotificationAccessSettings" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                // Controles de transporte sobre la sesión que seguimos.
                "play" -> { MediaSessionBridge.play(); result.success(null) }
                "pause" -> { MediaSessionBridge.pause(); result.success(null) }
                "skipToNext" -> { MediaSessionBridge.next(); result.success(null) }
                "skipToPrevious" -> { MediaSessionBridge.previous(); result.success(null) }
                "seekTo" -> {
                    val ms = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    MediaSessionBridge.seekTo(ms)
                    result.success(null)
                }
                // Vuelve a emitir el estado (con la posición recalculada):
                // Flutter lo pide cada tanto para corregir la deriva.
                "refresh" -> { MediaSessionBridge.start(); result.success(null) }
                "setPreferredPackage" -> {
                    MediaSessionBridge.preferredPackage = call.argument<String>("packageName")
                    result.success(null)
                }

                // --- Letra fuera de la app (notificación / widget / burbuja) ---
                "setLiveLyrics" -> {
                    LiveLyrics.title = call.argument<String>("title") ?: ""
                    LiveLyrics.artist = call.argument<String>("artist") ?: ""
                    LiveLyrics.packageName = call.argument<String>("packageName")
                    LiveLyrics.offsetMs = call.argument<Number>("offsetMs")?.toLong() ?: 0L
                    val raw = call.argument<List<List<Any>>>("lines") ?: emptyList()
                    LiveLyrics.lines = raw.map { (it[0] as Number).toLong() to (it[1] as String) }
                    LiveLyricsService.instance?.refresh(force = true)
                    result.success(null)
                }
                "setLiveOffset" -> {
                    LiveLyrics.offsetMs = call.argument<Number>("offsetMs")?.toLong() ?: 0L
                    LiveLyricsService.instance?.refresh(force = true)
                    result.success(null)
                }
                "clearLiveLyrics" -> {
                    LiveLyrics.clear()
                    LiveLyricsService.instance?.refresh(force = true)
                    result.success(null)
                }
                "setLiveOptions" -> {
                    LiveLyrics.notificationEnabled = call.argument<Boolean>("notification") ?: false
                    LiveLyrics.bubbleEnabled = call.argument<Boolean>("bubble") ?: false
                    LiveLyricsService.sync(app)
                    result.success(null)
                }
                "canDrawOverlays" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(app)
                )
                "openOverlaySettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        app.startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:${app.packageName}")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                    result.success(null)
                }
                "hasHomeWidgets" -> result.success(LyricsWidgetProvider.hasWidgets(app))
                // Instalar una actualización ya descargada (GitHub Releases).
                "canInstallPackages" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        app.packageManager.canRequestPackageInstalls()
                )
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        app.startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${app.packageName}")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "Falta el archivo", null)
                    } else {
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            app, "${app.packageName}.updates", java.io.File(path)
                        )
                        app.startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                }
                // Prueba de trabajo para publicar en LRCLIB: en Kotlin con
                // el SHA-256 nativo (acelerado por hardware) es varias veces
                // más rápido que en Dart. Corre en otro hilo.
                "solveLrclibChallenge" -> {
                    val prefix = call.argument<String>("prefix") ?: ""
                    val target = call.argument<String>("target") ?: ""
                    Thread {
                        val nonce = solveChallenge(prefix, target)
                        runOnUiThread { result.success(nonce) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                MediaSessionBridge.dartSink = sink
                MediaSessionBridge.start()
            }

            override fun onCancel(arguments: Any?) {
                MediaSessionBridge.dartSink = null
            }
        })

        EventChannel(messenger, SPOTIFY_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                spotifyRedirectSink = sink
                pendingSpotifyRedirect?.let {
                    pendingSpotifyRedirect = null
                    sink?.success(it)
                }
            }

            override fun onCancel(arguments: Any?) {
                spotifyRedirectSink = null
            }
        })
    }

    private fun solveChallenge(prefix: String, target: String): String {
        val targetBytes = ByteArray(target.length / 2) {
            target.substring(it * 2, it * 2 + 2).toInt(16).toByte()
        }
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val prefixBytes = prefix.toByteArray(Charsets.UTF_8)
        var nonce = 0L
        while (true) {
            digest.reset()
            digest.update(prefixBytes)
            val hash = digest.digest(nonce.toString().toByteArray(Charsets.UTF_8))
            var ok = true
            for (i in hash.indices) {
                val h = hash[i].toInt() and 0xff
                val t = targetBytes[i].toInt() and 0xff
                if (h < t) break
                if (h > t) { ok = false; break }
            }
            if (ok) return nonce.toString()
            nonce++
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    /** Si el intent trae la redirección de Spotify, se la mandamos a Flutter (o la guardamos). */
    private fun handleIncomingIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "io.letras.app" && data.host == "spotify-callback") {
            val uriString = data.toString()
            val sink = spotifyRedirectSink
            if (sink != null) sink.success(uriString) else pendingSpotifyRedirect = uriString
        }
    }

    /**
     * Cada vez que la app vuelve a primer plano (por ejemplo, al volver de
     * Ajustes tras dar el permiso de notificaciones) reintentamos
     * engancharnos a MediaSessionManager y refrescamos la sesión activa.
     * También es el momento seguro para arrancar el servicio de la letra
     * en vivo si quedó apagado (Android no deja arrancarlo desde atrás).
     */
    override fun onResume() {
        super.onResume()
        if (MediaSessionBridge.dartSink != null) MediaSessionBridge.start()
        LiveLyricsService.sync(applicationContext)
    }
}
