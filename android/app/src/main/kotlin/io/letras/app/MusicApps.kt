package io.letras.app

import android.app.SearchManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore

/**
 * Pedirle a Spotify o a Apple Music que pongan una canción elegida en Letras.
 *
 * Primero se intenta por la sesión multimedia que la app de música ya tiene
 * abierta (la misma que se usa para saber qué suena): así la canción
 * empieza sin que la app de música pase al frente. Si no hay sesión, se usa
 * el pedido estándar de Android "reproducir lo que se busca" (el mismo que
 * usa el asistente de Google), que abre la app.
 */
object MusicApps {
    const val SPOTIFY = "com.spotify.music"
    const val APPLE_MUSIC = "com.apple.android.music"

    fun pkg(app: String?): String = if (app == "apple") APPLE_MUSIC else SPOTIFY

    fun isInstalled(context: Context, pkg: String): Boolean =
        context.packageManager.getLaunchIntentForPackage(pkg) != null

    fun launch(context: Context, pkg: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        return try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Abre [url] (en [pkg] si se puede; si no, en lo que Android elija). */
    fun open(context: Context, url: String, pkg: String?): Boolean {
        if (url.isBlank()) return false
        val base = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(Intent.EXTRA_REFERRER, Uri.parse("android-app://${context.packageName}"))
        if (pkg != null && isInstalled(context, pkg)) {
            try {
                context.startActivity(Intent(base).setPackage(pkg))
                return true
            } catch (e: ActivityNotFoundException) {
                // Sigue sin paquete.
            }
        }
        return try {
            context.startActivity(base)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    fun playFromSearch(context: Context, pkg: String, title: String, artist: String, album: String?): Boolean {
        if (title.isBlank()) return false
        val query = listOf(title, artist).filter { it.isNotBlank() }.joinToString(" ")
        val extras = Bundle().apply {
            putString(MediaStore.EXTRA_MEDIA_FOCUS, MediaStore.Audio.Media.ENTRY_CONTENT_TYPE)
            putString(MediaStore.EXTRA_MEDIA_TITLE, title)
            if (artist.isNotBlank()) putString(MediaStore.EXTRA_MEDIA_ARTIST, artist)
            if (!album.isNullOrBlank()) putString(MediaStore.EXTRA_MEDIA_ALBUM, album)
            putString(SearchManager.QUERY, query)
        }

        // 1) Por la sesión multimedia abierta: sin sacar a Letras del frente.
        val controller = MediaSessionBridge.controllerFor(pkg)
        if (controller != null) {
            try {
                controller.transportControls.playFromSearch(query, extras)
                return true
            } catch (e: Exception) {
                // Sigue con el pedido por intent.
            }
        }

        // 2) El pedido estándar de Android (abre la app de música).
        if (!isInstalled(context, pkg)) return false
        val intent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
            .setPackage(pkg)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtras(extras)
        if (intent.resolveActivity(context.packageManager) == null) return false
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
