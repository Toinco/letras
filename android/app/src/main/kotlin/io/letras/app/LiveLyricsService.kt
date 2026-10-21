package io.letras.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings

/**
 * Letra que Flutter le pasa al lado nativo para mostrar fuera de la app.
 * Las líneas son (milisegundo de inicio, texto), ya ordenadas.
 */
object LiveLyrics {
    var title: String = ""
    var artist: String = ""
    var packageName: String? = null
    var lines: List<Pair<Long, String>> = emptyList()
    var offsetMs: Long = 0L

    /** Opciones de Ajustes. */
    var notificationEnabled = false
    var bubbleEnabled = false

    fun clear() {
        title = ""
        artist = ""
        packageName = null
        lines = emptyList()
    }

    /** Índice de la línea que corresponde a [positionMs] (-1 = todavía no empezó). */
    fun indexAt(positionMs: Long): Int {
        val pos = positionMs + offsetMs
        var lo = 0
        var hi = lines.size - 1
        var ans = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (lines[mid].first <= pos) {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }
}

/**
 * Servicio en primer plano que sigue la canción por su cuenta (lee la
 * posición directo de la sesión multimedia, sin depender de Flutter) y
 * mantiene actualizados, con la línea que se está cantando:
 *  - una notificación fija (se ve sin abrir la app),
 *  - el widget de la pantalla de inicio,
 *  - la burbuja flotante encima de otras apps (si se activó).
 *
 * Android exige mostrar una notificación mientras corre un servicio así,
 * por eso la notificación siempre está mientras el servicio vive.
 */
class LiveLyricsService : Service() {

    companion object {
        private const val CHANNEL_ID = "live_lyrics"
        private const val NOTIFICATION_ID = 4711
        private const val ACTION_STOP = "io.letras.app.STOP_LIVE"

        @Volatile
        var instance: LiveLyricsService? = null

        /** Arranca, actualiza o frena el servicio según las opciones y la letra actual. */
        fun sync(context: Context) {
            val wanted = LiveLyrics.notificationEnabled || LiveLyrics.bubbleEnabled
            val running = instance
            if (!wanted) {
                running?.stopSelfCleanly()
                return
            }
            if (running != null) {
                running.refresh(force = true)
                return
            }
            try {
                val intent = Intent(context, LiveLyricsService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ no deja arrancarlo desde segundo plano: se
                // arranca la próxima vez que se abra la app.
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var lastIndex = Int.MIN_VALUE
    private var lastTitle = ""
    private var lastPlaying: Boolean? = null
    private var bubble: FloatingLyricsBubble? = null

    private val onSessionChanged: () -> Unit = { refresh(force = false) }

    private val ticker = object : Runnable {
        override fun run() {
            refresh(force = false)
            val playing = MediaSessionBridge.current()?.playbackState?.state == PlaybackState.STATE_PLAYING
            handler.postDelayed(this, if (playing) 200L else 1000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        MediaSessionBridge.init(this)
        MediaSessionBridge.start()
        createChannel()
        val notification = buildNotification("Letras", "Esperando una canción…", null)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        MediaSessionBridge.listeners.add(onSessionChanged)
        handler.post(ticker)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // "Ocultar" desde la notificación: se apaga hasta que se vuelva
            // a activar desde Ajustes.
            LiveLyrics.notificationEnabled = false
            LiveLyrics.bubbleEnabled = false
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).edit()
                .putBoolean("flutter.live_notification", false)
                .putBoolean("flutter.floating_bubble", false)
                .apply()
            stopSelfCleanly()
            return START_NOT_STICKY
        }
        refresh(force = true)
        return START_STICKY
    }

    fun stopSelfCleanly() {
        handler.removeCallbacks(ticker)
        MediaSessionBridge.listeners.remove(onSessionChanged)
        bubble?.remove()
        bubble = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(ticker)
        MediaSessionBridge.listeners.remove(onSessionChanged)
        bubble?.remove()
        bubble = null
        instance = null
        super.onDestroy()
    }

    /** Recalcula la línea actual y, si cambió, actualiza todo. */
    fun refresh(force: Boolean) {
        val controller = MediaSessionBridge.current()
        val state = controller?.playbackState
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val song = LiveLyrics.title
        val lines = LiveLyrics.lines

        val index = if (lines.isEmpty() || controller == null) -1
        else LiveLyrics.indexAt(MediaSessionBridge.positionMs(state))

        if (!force && index == lastIndex && song == lastTitle && playing == lastPlaying) return
        lastIndex = index
        lastTitle = song
        lastPlaying = playing

        val current: String
        val next: String?
        when {
            song.isEmpty() -> {
                current = "Letras"
                next = "Esperando una canción…"
            }
            lines.isEmpty() -> {
                current = song
                next = "Sin letra sincronizada"
            }
            index < 0 -> {
                current = "♪"
                next = lines.firstOrNull()?.second
            }
            else -> {
                current = lines[index].second.ifBlank { "♪" }
                next = lines.getOrNull(index + 1)?.second?.ifBlank { "♪" }
            }
        }
        val subtitle = if (song.isEmpty()) null else "$song · ${LiveLyrics.artist}"

        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(current, next, subtitle))
        LyricsWidgetProvider.push(this, current, next, subtitle)
        updateBubble(current, next)
    }

    private fun updateBubble(current: String, next: String?) {
        val canDraw = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
        if (LiveLyrics.bubbleEnabled && canDraw) {
            val b = bubble ?: FloatingLyricsBubble(this) {
                // La "X" de la burbuja la apaga.
                LiveLyrics.bubbleEnabled = false
                getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).edit()
                    .putBoolean("flutter.floating_bubble", false).apply()
                bubble?.remove()
                bubble = null
                if (!LiveLyrics.notificationEnabled) stopSelfCleanly()
            }.also { bubble = it; it.show() }
            b.setLines(current, next)
        } else if (bubble != null) {
            bubble?.remove()
            bubble = null
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID, "Letra en vivo", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "La línea que se está cantando, sin abrir la app"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String?, subText: String?): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, LiveLyricsService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_lyrics)
            .setContentTitle(title)
            .setContentText(text ?: "")
            .setStyle(Notification.BigTextStyle().bigText(text ?: ""))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openApp)
            .setColor(0xFFFC3C44.toInt())
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Ocultar", stop).build())
        if (subText != null) builder.setSubText(subText)
        return builder.build()
    }
}
