package io.letras.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews

/**
 * Widget de pantalla de inicio con la línea que se está cantando. Lo
 * actualiza LiveLyricsService cada vez que cambia la línea; si el servicio
 * no está corriendo, muestra lo último que se vio y un toque abre la app.
 */
class LyricsWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val PREFS = "lyrics_widget"

        fun hasWidgets(context: Context): Boolean {
            val ids = AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, LyricsWidgetProvider::class.java))
            return ids.isNotEmpty()
        }

        /** Guarda y muestra [current]/[next] en todos los widgets puestos. */
        fun push(context: Context, current: String, next: String?, subtitle: String?) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("current", current)
                .putString("next", next)
                .putString("subtitle", subtitle)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, LyricsWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = build(context, current, next, subtitle)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        private fun build(context: Context, current: String, next: String?, subtitle: String?): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_lyrics)
            views.setTextViewText(R.id.widget_current, current)
            views.setTextViewText(R.id.widget_next, next ?: "")
            views.setViewVisibility(R.id.widget_next, if (next.isNullOrBlank()) View.GONE else View.VISIBLE)
            views.setTextViewText(R.id.widget_song, subtitle ?: "Letras")
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            views.setOnClickPendingIntent(R.id.widget_root, open)
            return views
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val running = LiveLyricsService.instance != null
        val current = if (running) prefs.getString("current", null) else null
        val views = build(
            context,
            current ?: "Toca para abrir Letras",
            if (running) prefs.getString("next", null)
            else "Activa \"Letra fuera de la app\" en Ajustes para ver la línea actual aquí",
            if (running) prefs.getString("subtitle", null) else null,
        )
        for (id in ids) manager.updateAppWidget(id, views)
    }
}
