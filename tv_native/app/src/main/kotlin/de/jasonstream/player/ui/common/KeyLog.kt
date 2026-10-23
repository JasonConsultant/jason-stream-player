package de.jasonstream.player.ui.common

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import de.jasonstream.player.R as AppR

/**
 * Verstecktes „Tasten-Protokoll“ (Einstellungen → Über: 5× OK auf die
 * Version). Zeigt die letzten 8 Tastenereignisse (Taste, ↓/↑, repeatCount,
 * ms seit dem vorigen, ob das Tasten-Tor sie zusammengefasst hat) und das
 * fokussierte Element (Testkennzeichen + Text) – zum Abfotografieren, wenn
 * etwas springt. Standardmäßig aus, nur im Speicher (nach Neustart aus).
 */
object KeyLog {
    @Immutable
    data class Entry(val key: String, val down: Boolean, val repeat: Int, val sinceMs: Long, val dropped: Boolean)

    var enabled by mutableStateOf(false)
    val entries = mutableStateListOf<Entry>()
    private var lastAt = -1L

    fun toggle(): Boolean {
        enabled = !enabled
        entries.clear()
        lastAt = -1L
        return enabled
    }

    fun record(ev: AndroidKeyEvent, dropped: Boolean = false) {
        if (!enabled) return
        if (ev.action != AndroidKeyEvent.ACTION_DOWN && ev.action != AndroidKeyEvent.ACTION_UP) return
        val since = if (lastAt < 0) 0 else ev.eventTime - lastAt
        lastAt = ev.eventTime
        val name = keyName(ev.keyCode)
        entries.add(Entry(name, ev.action == AndroidKeyEvent.ACTION_DOWN, ev.repeatCount, since, dropped))
        while (entries.size > 8) entries.removeAt(0)
    }

    /** Kurzname der Fernbedienungstaste (feste Tabelle, sonst Systemname/Zahl). */
    fun keyName(code: Int): String = when (code) {
        AndroidKeyEvent.KEYCODE_DPAD_UP -> "DPAD_UP"
        AndroidKeyEvent.KEYCODE_DPAD_DOWN -> "DPAD_DOWN"
        AndroidKeyEvent.KEYCODE_DPAD_LEFT -> "DPAD_LEFT"
        AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> "DPAD_RIGHT"
        AndroidKeyEvent.KEYCODE_DPAD_CENTER -> "OK"
        AndroidKeyEvent.KEYCODE_ENTER -> "ENTER"
        AndroidKeyEvent.KEYCODE_BACK -> "BACK"
        AndroidKeyEvent.KEYCODE_MENU -> "MENU"
        AndroidKeyEvent.KEYCODE_CHANNEL_UP -> "CH+"
        AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> "CH-"
        AndroidKeyEvent.KEYCODE_PAGE_UP -> "PAGE_UP"
        AndroidKeyEvent.KEYCODE_PAGE_DOWN -> "PAGE_DOWN"
        AndroidKeyEvent.KEYCODE_INFO -> "INFO"
        AndroidKeyEvent.KEYCODE_GUIDE -> "GUIDE"
        AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> "PLAY_PAUSE"
        in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 -> "${code - AndroidKeyEvent.KEYCODE_0}"
        else -> AndroidKeyEvent.keyCodeToString(code).removePrefix("KEYCODE_")
    }

    fun format(e: Entry): String =
        "%-12s %s r=%-2d +%4d ms%s".format(e.key.take(12), if (e.down) "↓" else "↑", e.repeat, e.sinceMs, if (e.dropped) "  ×" else "")

    /** Fokussiertes Element im Fenster von [root]: Testkennzeichen-Pfad + Text. */
    fun describeFocus(root: RootForTest?): String {
        val owner = root?.semanticsOwner ?: return "–"
        var found: SemanticsNode? = null
        fun walk(n: SemanticsNode) {
            if (found != null) return
            if (n.config.getOrNull(SemanticsProperties.Focused) == true) { found = n; return }
            n.children.forEach(::walk)
        }
        runCatching { walk(owner.unmergedRootSemanticsNode) }
        val f = found ?: return "– (Dialog?)"
        val tags = ArrayList<String>()
        var x: SemanticsNode? = f
        while (x != null) {
            x.config.getOrNull(SemanticsProperties.TestTag)?.let { tags += it }
            x = x.parent
        }
        val texts = ArrayList<String>()
        fun text(n: SemanticsNode) {
            if (texts.size >= 2) return
            n.config.getOrNull(SemanticsProperties.Text)?.forEach { texts += it.text }
            n.config.getOrNull(SemanticsProperties.EditableText)?.let { texts += it.text }
            n.children.forEach(::text)
        }
        text(f)
        val path = tags.reversed().joinToString(" › ").ifEmpty { "#${f.id}" }
        return "$path · ${texts.joinToString(" | ").take(40)}"
    }
}

/** Anzeige oben rechts (nicht fokussierbar). */
@Composable
fun KeyLogOverlay() {
    if (!KeyLog.enabled) return
    val view = LocalView.current
    var focus by remember { mutableStateOf("–") }
    val last = KeyLog.entries.lastOrNull()
    LaunchedEffect(last, KeyLog.entries.size) {
        withFrameNanos { }
        focus = KeyLog.describeFocus(view as? RootForTest)
    }
    Box(Modifier.fillMaxSize().padding(top = 56.dp, end = 12.dp), contentAlignment = Alignment.TopEnd) {
        Column(
            Modifier.width(270.dp).background(Color(0xD9000000), RoundedCornerShape(6.dp))
                .padding(horizontal = 8.dp, vertical = 6.dp).testTag("keylog"),
        ) {
            Text(stringResource(AppR.string.tv_keyLogTitle), color = Color(0xFFFFC14D), fontSize = 8.sp, fontWeight = FontWeight.Bold)
            for (e in KeyLog.entries) {
                Text(
                    KeyLog.format(e), color = if (e.dropped) Color(0xFF9AA1B2) else Color.White,
                    fontFamily = FontFamily.Monospace, fontSize = 7.5.sp, maxLines = 1,
                )
            }
            Text(
                "Fokus: $focus", color = Color(0xFF8FD3FF), fontFamily = FontFamily.Monospace, fontSize = 7.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 3.dp),
            )
        }
    }
}
