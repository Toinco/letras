package io.letras.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * Burbuja flotante con la letra, encima de Spotify o cualquier otra app
 * (permiso "Mostrar sobre otras apps"). Se puede arrastrar; un toque la
 * achica a una pastilla con solo la línea actual y otro la vuelve a
 * agrandar. La "×" la apaga.
 */
class FloatingLyricsBubble(
    private val context: Context,
    private val onClose: () -> Unit,
) {
    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var root: FrameLayout? = null
    private lateinit var currentView: TextView
    private lateinit var nextView: TextView
    private var collapsed = false

    private fun dp(v: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, context.resources.displayMetrics).toInt()

    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = 0
        y = 0
    }

    @SuppressLint("ClickableViewAccessibility")
    fun show() {
        if (root != null) return
        val metrics = context.resources.displayMetrics
        params.x = dp(16f)
        params.y = (metrics.heightPixels * 0.18f).toInt()

        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16f), dp(12f), dp(36f), dp(12f))
            background = GradientDrawable().apply {
                cornerRadius = dp(18f).toFloat()
                setColor(0xE6141414.toInt())
                setStroke(dp(1f), 0x33FFFFFF)
            }
            elevation = dp(8f).toFloat()
        }
        currentView = TextView(context).apply {
            setTextColor(0xFFFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            typeface = Typeface.DEFAULT_BOLD
            maxWidth = (metrics.widthPixels * 0.78f).toInt()
        }
        nextView = TextView(context).apply {
            setTextColor(0x8CFFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            maxWidth = (metrics.widthPixels * 0.78f).toInt()
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(4f), 0, 0)
        }
        card.addView(currentView)
        card.addView(nextView)

        val close = TextView(context).apply {
            text = "×"
            setTextColor(0xB3FFFFFF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(10f), dp(4f), dp(10f), dp(4f))
            setOnClickListener { onClose() }
        }

        val frame = FrameLayout(context)
        frame.addView(card)
        frame.addView(
            close,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.END
            )
        )

        // Arrastrar para mover; un toque sin moverse achica/agranda.
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var moved = false
        card.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = e.rawX
                    touchY = e.rawY
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - touchX
                    val dy = e.rawY - touchY
                    if (abs(dx) > dp(4f) || abs(dy) > dp(4f)) moved = true
                    params.x = startX + dx.toInt()
                    params.y = startY + dy.toInt()
                    root?.let { wm.updateViewLayout(it, params) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) toggleCollapsed()
                    true
                }
                else -> false
            }
        }

        root = frame
        try {
            wm.addView(frame, params)
        } catch (e: Exception) {
            // Sin permiso de superposición: no mostramos nada.
            root = null
        }
    }

    private fun toggleCollapsed() {
        collapsed = !collapsed
        nextView.visibility = if (collapsed) View.GONE else View.VISIBLE
        currentView.maxLines = if (collapsed) 1 else Int.MAX_VALUE
        currentView.ellipsize = if (collapsed) TextUtils.TruncateAt.END else null
    }

    fun setLines(current: String, next: String?) {
        if (root == null) return
        currentView.text = current
        nextView.text = next ?: ""
        nextView.visibility = if (collapsed || next.isNullOrBlank()) View.GONE else View.VISIBLE
    }

    fun remove() {
        root?.let {
            try {
                wm.removeView(it)
            } catch (e: Exception) {
            }
        }
        root = null
    }
}
