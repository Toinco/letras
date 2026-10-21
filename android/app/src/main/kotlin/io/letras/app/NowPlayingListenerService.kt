package io.letras.app

import android.service.notification.NotificationListenerService

/**
 * Servicio "oyente de notificaciones" vacío.
 *
 * Su única razón de ser es aparecer declarado en el AndroidManifest para
 * que Android habilite la opción "Acceso a notificaciones" en Ajustes para
 * esta app. Toda la lógica real de leer qué se está reproduciendo vive en
 * MainActivity, que usa MediaSessionManager una vez que este permiso está
 * concedido (no hace falta que este servicio esté corriendo activamente).
 */
class NowPlayingListenerService : NotificationListenerService()
