package dev.domlab.dom_lab

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.ImageView
import kotlin.math.abs

/**
 * Servizio di accessibilità di D. Dom Lab: legge lo schermo, tocca, scrive
 * e scorre al posto dell'utente. Mostra anche una bolla col microfono sopra
 * le altre app (overlay di accessibilità, nessun permesso in più).
 */
class DomA11yService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: DomA11yService? = null
            private set

        /** Elementi dell'ultima lettura dello schermo, per id. */
        private val nodes = HashMap<Int, AccessibilityNodeInfo>()
        private var lastPackage = ""
    }

    private var bubble: View? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        if (Prefs.bubble(this)) showBubble()
        // Riattiva "Ciao Dom" se era acceso (es. dopo un riavvio).
        if (Prefs.wake(this) && WakeWordService.instance == null) {
            try {
                WakeWordService.start(this)
            } catch (_: Exception) {
            }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val p = event?.packageName?.toString() ?: return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && p.isNotEmpty()) {
            lastPackage = p
        }
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        hideBubble()
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        hideBubble()
        instance = null
        super.onDestroy()
    }

    // ---------- Lettura dello schermo ----------

    /** Restituisce l'app in primo piano e gli elementi visibili. */
    fun readScreen(): Map<String, Any> {
        nodes.clear()
        val out = ArrayList<Map<String, Any?>>()
        val root = activeRoot()
        val pkg = root?.packageName?.toString() ?: lastPackage
        if (root != null) walk(root, out, 0)
        return mapOf("package" to pkg, "nodes" to out)
    }

    private fun activeRoot(): AccessibilityNodeInfo? {
        rootInActiveWindow?.let { return it }
        // Con overlay o tastiera aperta, prendi la finestra dell'app.
        return windows
            .filter { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION }
            .firstNotNullOfOrNull { it.root }
    }

    private fun walk(n: AccessibilityNodeInfo, out: ArrayList<Map<String, Any?>>, depth: Int) {
        if (depth > 40 || out.size > 400) return
        if (!n.isVisibleToUser) return
        val text = n.text?.toString()?.trim() ?: ""
        val desc = n.contentDescription?.toString()?.trim() ?: ""
        val hint = if (android.os.Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim() ?: "" else ""
        val useful = text.isNotEmpty() || desc.isNotEmpty() || n.isClickable || n.isEditable || n.isScrollable || n.isCheckable
        if (useful) {
            val id = nodes.size + 1
            nodes[id] = n
            out.add(
                mapOf(
                    "id" to id,
                    "text" to if (text.isEmpty() && n.isEditable) hint else text,
                    "desc" to desc,
                    "viewId" to (n.viewIdResourceName ?: ""),
                    "cls" to (n.className?.toString()?.substringAfterLast('.') ?: ""),
                    "clickable" to (n.isClickable || clickableParent(n) != null && (text.isNotEmpty() || desc.isNotEmpty())),
                    "editable" to n.isEditable,
                    "scrollable" to n.isScrollable,
                    "checked" to if (n.isCheckable) n.isChecked else null,
                )
            )
        }
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            walk(c, out, depth + 1)
        }
    }

    private fun clickableParent(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var p: AccessibilityNodeInfo? = n
        var hops = 0
        while (p != null && hops < 6) {
            if (p.isClickable) return p
            p = p.parent
            hops++
        }
        return null
    }

    // ---------- Azioni ----------

    fun tap(id: Int): Boolean {
        val n = nodes[id] ?: return false
        val target = clickableParent(n)
        if (target != null && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
        // Ultima possibilità: un tocco vero al centro dell'elemento.
        val r = Rect()
        n.getBoundsInScreen(r)
        if (r.isEmpty) return false
        return gesture(r.exactCenterX(), r.exactCenterY(), r.exactCenterX(), r.exactCenterY(), 60)
    }

    fun typeText(id: Int, text: String): Boolean {
        val n = nodes[id] ?: return false
        n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun scroll(direction: String): Boolean {
        // Il contenitore scorrevole più grande sullo schermo.
        val scrollables = nodes.values.filter { it.isScrollable }
        val best = scrollables.maxByOrNull {
            val r = Rect(); it.getBoundsInScreen(r); r.width() * r.height()
        }
        val action = if (direction == "up") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        if (best != null && best.performAction(action)) return true
        // Altrimenti un trascinamento con il dito.
        val dm: DisplayMetrics = resources.displayMetrics
        val x = dm.widthPixels / 2f
        val top = dm.heightPixels * 0.3f
        val bottom = dm.heightPixels * 0.75f
        return if (direction == "up") gesture(x, top, x, bottom, 350) else gesture(x, bottom, x, top, 350)
    }

    fun global(action: String): Boolean = when (action) {
        "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
        "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
        "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        else -> false
    }

    private fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, ms: Long): Boolean {
        val path = Path()
        path.moveTo(x1, y1)
        if (abs(x1 - x2) > 1 || abs(y1 - y2) > 1) path.lineTo(x2, y2)
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, ms))
            .build()
        return dispatchGesture(g, null, null)
    }

    /** Apre l'app dal servizio: consentito anche quando D. Dom Lab è in background. */
    fun launch(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }

    // ---------- Bolla microfono ----------

    @SuppressLint("ClickableViewAccessibility")
    fun showBubble() {
        if (bubble != null) return
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val size = (56 * resources.displayMetrics.density).toInt()
        val view = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_btn_speak_now)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFF1D3A8A.toInt())
                setStroke((2 * resources.displayMetrics.density).toInt(), 0xFFF28C38.toInt())
            }
            elevation = 8f
            contentDescription = "Parla con Dom"
        }
        val lp = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - size - 16
            y = (resources.displayMetrics.heightPixels * 0.55).toInt()
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        view.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = lp.x; startY = lp.y; moved = false; true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (abs(dx) > 12 || abs(dy) > 12) moved = true
                    if (moved) {
                        lp.x = startX + dx.toInt()
                        lp.y = startY + dy.toInt()
                        wm.updateViewLayout(v, lp)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) wake("bubble")
                    true
                }
                else -> false
            }
        }
        try {
            wm.addView(view, lp)
            bubble = view
        } catch (_: Exception) {
        }
    }

    fun hideBubble() {
        val b = bubble ?: return
        try {
            (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(b)
        } catch (_: Exception) {
        }
        bubble = null
    }

    /** Sveglia l'assistente: porta D. Dom Lab in primo piano e inizia ad ascoltare. */
    fun wake(source: String) {
        // Se il microfono è già disponibile in background, niente cambio schermata.
        if (MainActivity.deliverWake(source)) return
        launch(Intent(this, MainActivity::class.java).putExtra("wake", source)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
    }
}
