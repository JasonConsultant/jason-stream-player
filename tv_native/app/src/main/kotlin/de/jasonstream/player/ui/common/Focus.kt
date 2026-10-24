package de.jasonstream.player.ui.common

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.focusable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusState
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.KeyInputModifierNode
import androidx.compose.ui.input.key.type
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.focus.FocusEventModifierNode
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** OK-Tasten der Fernbedienung (inkl. Tastatur/Gamepad). */
fun isOkKey(code: Int) = code == AndroidKeyEvent.KEYCODE_DPAD_CENTER || code == AndroidKeyEvent.KEYCODE_ENTER ||
    code == AndroidKeyEvent.KEYCODE_NUMPAD_ENTER || code == AndroidKeyEvent.KEYCODE_BUTTON_A

// ---------------------------------------------------------------- OK / lange OK

private class TvClickNode(var onClick: () -> Unit, var onLong: (() -> Unit)?) : Modifier.Node(), KeyInputModifierNode {
    private var down = false
    private var longFired = false

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val code = event.nativeKeyEvent.keyCode
        val native = event.nativeKeyEvent
        if (code == AndroidKeyEvent.KEYCODE_MENU) {
            val l = onLong ?: return false
            if (event.type == KeyEventType.KeyUp) l()
            return true
        }
        if (!isOkKey(code)) return false
        when (event.type) {
            KeyEventType.KeyDown -> {
                if (native.repeatCount == 0) {
                    down = true
                    longFired = false
                } else if (down && !longFired && onLong != null) {
                    longFired = true
                    onLong?.invoke()
                }
                return true
            }
            KeyEventType.KeyUp -> {
                val wasDown = down
                down = false
                if (wasDown && !longFired) onClick()
                return wasDown
            }
        }
        return false
    }

    override fun onPreKeyEvent(event: KeyEvent) = false
}

private data class TvClickElement(val onClick: () -> Unit, val onLong: (() -> Unit)?) : ModifierNodeElement<TvClickNode>() {
    override fun create() = TvClickNode(onClick, onLong)
    override fun update(node: TvClickNode) {
        node.onClick = onClick
        node.onLong = onLong
    }
}

/**
 * Fokussierbar + OK (kurz) / lange OK oder Menü-Taste. Nur Fernbedienung –
 * keine Zeiger-Gesten (spart Arbeit in langen Listen).
 */
fun Modifier.tvClick(onLongClick: (() -> Unit)? = null, onClick: () -> Unit): Modifier =
    this.then(TvClickElement(onClick, onLongClick)).focusable()

// ---------------------------------------------------------------- Fokus-Darstellung

private class FocusDrawNode(
    var ring: Color,
    var focusedBg: Color,
    var bg: Color,
    var radius: Dp,
    var width: Dp,
) : Modifier.Node(), FocusEventModifierNode, DrawModifierNode {
    private var focused = false

    override fun onFocusEvent(focusState: FocusState) {
        if (focused != focusState.isFocused) {
            focused = focusState.isFocused
            // Statistik: Zeit vom Tastendruck bis zum Fokuswechsel.
            if (focused) de.jasonstream.playback.stats.PlaybackStats.session.onFocusGained()
            invalidateDraw()
        }
    }

    override fun ContentDrawScope.draw() {
        val r = radius.toPx()
        val fill = if (focused) focusedBg else bg
        if (fill.alpha > 0f) drawRoundRect(fill, cornerRadius = CornerRadius(r, r))
        drawContent()
        if (focused && ring.alpha > 0f) {
            val w = width.toPx()
            drawRoundRect(
                ring, topLeft = Offset(w / 2, w / 2), size = Size(size.width - w, size.height - w),
                cornerRadius = CornerRadius(r, r), style = Stroke(w),
            )
        }
    }
}

private data class FocusDrawElement(val ring: Color, val focusedBg: Color, val bg: Color, val radius: Dp, val width: Dp) :
    ModifierNodeElement<FocusDrawNode>() {
    override fun create() = FocusDrawNode(ring, focusedBg, bg, radius, width)
    override fun update(node: FocusDrawNode) {
        node.ring = ring; node.focusedBg = focusedBg; node.bg = bg; node.radius = radius; node.width = width
        node.invalidateDraw()
    }
}

/**
 * Hintergrund + Fokusring, nur in der Zeichenphase (Fokuswechsel löst
 * keine Neukomposition aus). Vor [tvClick] anwenden.
 */
fun Modifier.focusRing(
    ring: Color,
    focusedBg: Color = Color.Transparent,
    bg: Color = Color.Transparent,
    radius: Dp = 12.dp,
    width: Dp = 1.5.dp,
): Modifier = this.then(FocusDrawElement(ring, focusedBg, bg, radius, width))

/** Fokus als Compose-Zustand (nur wo sich Inhalt/Textfarbe ändert). */
@Composable
fun rememberFocused(): Pair<Boolean, Modifier> {
    var f by remember { mutableStateOf(false) }
    val m = remember { Modifier.onFocusChanged { f = it.isFocused } }
    return f to m
}
