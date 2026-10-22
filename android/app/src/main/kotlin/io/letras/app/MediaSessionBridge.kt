package io.letras.app

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream

/**
 * Lee la sesión multimedia activa del teléfono (Spotify, YouTube Music,
 * etc.) con MediaSessionManager, usando el permiso "Acceso a
 * notificaciones".
 *
 * Antes esto vivía adentro de MainActivity, así que solo funcionaba con la
 * app abierta. Ahora es un singleton atado al contexto de la aplicación:
 * lo usan tanto Flutter (por el EventChannel) como LiveLyricsService (la
 * notificación / widget / burbuja con la línea actual), aunque la
 * pantalla de la app esté cerrada.
 */
object MediaSessionBridge {

    private var appContext: Context? = null
    private var manager: MediaSessionManager? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Controladores activos, por token de sesión (el mismo reproductor
    // devuelve un objeto MediaController nuevo en cada consulta).
    private val controllers = LinkedHashMap<MediaSession.Token, MediaController>()
    private val callbacks = HashMap<MediaSession.Token, MediaController.Callback>()
    private var listening = false

    /** Sink del EventChannel de Flutter (null si Flutter no está escuchando). */
    var dartSink: EventChannel.EventSink? = null

    /** App de música elegida a mano cuando suenan dos a la vez (null = automático). */
    var preferredPackage: String? = null
        set(value) {
            field = value
            emit()
        }

    /** Otros interesados en los cambios (LiveLyricsService). */
    val listeners = mutableSetOf<() -> Unit>()

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { list -> updateControllers(list ?: emptyList()) }

    fun init(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        manager = context.applicationContext
            .getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    }

    fun isAccessGranted(): Boolean {
        val ctx = appContext ?: return false
        val enabled = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
        return enabled != null && enabled.contains(ctx.packageName)
    }

    private fun component(): ComponentName =
        ComponentName(appContext!!, NowPlayingListenerService::class.java)

    /**
     * Se engancha a MediaSessionManager si todavía no lo hizo (por ejemplo,
     * si el permiso se dio recién) y refresca la lista de sesiones.
     */
    fun start() {
        val mgr = manager ?: return
        if (!isAccessGranted()) {
            listening = false
            emit()
            return
        }
        try {
            if (!listening) {
                mgr.addOnActiveSessionsChangedListener(sessionsListener, component(), mainHandler)
                listening = true
            }
            updateControllers(mgr.getActiveSessions(component()))
        } catch (e: SecurityException) {
            listening = false
            emit()
        }
    }

    private fun updateControllers(list: List<MediaController>) {
        val tokens = list.map { it.sessionToken }.toSet()
        for ((token, controller) in controllers.toMap()) {
            if (token !in tokens) {
                callbacks.remove(token)?.let { controller.unregisterCallback(it) }
                controllers.remove(token)
            }
        }
        for (controller in list) {
            val token = controller.sessionToken
            if (controllers.containsKey(token)) continue
            controllers[token] = controller
            val cb = object : MediaController.Callback() {
                override fun onMetadataChanged(metadata: MediaMetadata?) = emit()
                override fun onPlaybackStateChanged(state: PlaybackState?) = emit()
                override fun onQueueChanged(queue: MutableList<MediaSession.QueueItem>?) = emit()
                override fun onSessionDestroyed() {
                    callbacks.remove(token)
                    controllers.remove(token)
                    emit()
                }
            }
            controller.registerCallback(cb, mainHandler)
            callbacks[token] = cb
        }
        emit()
    }

    /**
     * El reproductor a seguir: el elegido a mano si está activo, si no el
     * que esté sonando, si no el primero.
     */
    fun current(): MediaController? {
        val all = controllers.values
        preferredPackage?.let { pkg ->
            all.firstOrNull { it.packageName == pkg }?.let { return it }
        }
        return all.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: all.firstOrNull()
    }

    /**
     * Posición REAL de reproducción en este instante. `PlaybackState.position`
     * es la posición en el momento `lastPositionUpdateTime` (que puede ser de
     * hace varios segundos: Spotify solo la actualiza al pausar, hacer seek,
     * etc.), así que hay que sumarle lo que pasó desde entonces multiplicado
     * por la velocidad. Sin esto la letra arrancaba atrasada.
     */
    fun positionMs(state: PlaybackState?): Long {
        if (state == null) return 0L
        val base = state.position
        if (state.state != PlaybackState.STATE_PLAYING) return base
        val updatedAt = state.lastPositionUpdateTime
        if (updatedAt <= 0L) return base
        val elapsed = SystemClock.elapsedRealtime() - updatedAt
        val speed = if (state.playbackSpeed > 0f) state.playbackSpeed else 1f
        return base + (elapsed * speed).toLong()
    }

    // La carátula se comprime una sola vez por canción.
    private var cachedArtKey: String? = null
    private var cachedArtBytes: ByteArray? = null

    private fun albumArtBytes(metadata: MediaMetadata?, key: String): ByteArray? {
        if (key == cachedArtKey && cachedArtBytes != null) return cachedArtBytes
        val bitmap: Bitmap = metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            ?: return null
        return try {
            val maxSize = 640
            val scaled = if (bitmap.width > maxSize || bitmap.height > maxSize) {
                val ratio = minOf(maxSize.toFloat() / bitmap.width, maxSize.toFloat() / bitmap.height)
                Bitmap.createScaledBitmap(
                    bitmap, (bitmap.width * ratio).toInt(), (bitmap.height * ratio).toInt(), true
                )
            } else {
                bitmap
            }
            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 88, stream)
            stream.toByteArray().also {
                cachedArtKey = key
                cachedArtBytes = it
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Próxima canción de la cola, si la app de música la expone. */
    private fun nextInQueue(controller: MediaController): Pair<String, String>? {
        return try {
            val queue = controller.queue ?: return null
            val activeId = controller.playbackState?.activeQueueItemId ?: return null
            val index = queue.indexOfFirst { it.queueId == activeId }
            if (index < 0 || index + 1 >= queue.size) return null
            val desc = queue[index + 1].description
            val title = desc.title?.toString() ?: return null
            Pair(title, desc.subtitle?.toString() ?: "")
        } catch (e: Exception) {
            null
        }
    }

    /** Estado actual para Flutter (null = no suena nada). */
    fun stateMap(): HashMap<String, Any?>? {
        val controller = current() ?: return null
        val metadata = controller.metadata
        val playbackState = controller.playbackState
        val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        if (title.isEmpty()) return null
        val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: ""
        val album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM)

        val map = HashMap<String, Any?>()
        map["title"] = title
        map["artist"] = artist
        map["album"] = album
        map["durationMs"] = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        // La hora exacta (reloj del teléfono) en que vale esa posición: Flutter
        // la usa para interpolar. Si tomara la hora de cuando le llega el
        // evento, lo que tarda en armarse (carátula) y en cruzar el canal
        // dejaría la letra atrasada.
        map["capturedAtMs"] = System.currentTimeMillis()
        map["positionMs"] = positionMs(playbackState)
        map["isPlaying"] = playbackState?.state == PlaybackState.STATE_PLAYING
        map["playbackSpeed"] = (playbackState?.playbackSpeed ?: 1f).toDouble()
        map["packageName"] = controller.packageName
        map["albumArt"] = albumArtBytes(metadata, "${controller.packageName}|$title|$artist|$album")
        nextInQueue(controller)?.let { (t, a) ->
            map["nextTitle"] = t
            map["nextArtist"] = a
        }
        // Todos los reproductores con algo cargado, para poder elegir cuál
        // seguir cuando suenan dos a la vez.
        map["players"] = controllers.values.mapNotNull { c ->
            val t = c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: return@mapNotNull null
            hashMapOf<String, Any?>(
                "packageName" to c.packageName,
                "title" to t,
                "artist" to (c.metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""),
                "isPlaying" to (c.playbackState?.state == PlaybackState.STATE_PLAYING),
            )
        }
        map["preferredPackage"] = preferredPackage
        return map
    }

    fun emit() {
        val map = stateMap()
        mainHandler.post {
            dartSink?.success(map)
            listeners.toList().forEach { it() }
        }
    }

    // --- Controles de transporte sobre el reproductor seguido ---
    fun play() = current()?.transportControls?.play()
    fun pause() = current()?.transportControls?.pause()
    fun next() = current()?.transportControls?.skipToNext()
    fun previous() = current()?.transportControls?.skipToPrevious()
    fun seekTo(ms: Long) = current()?.transportControls?.seekTo(ms)
}
