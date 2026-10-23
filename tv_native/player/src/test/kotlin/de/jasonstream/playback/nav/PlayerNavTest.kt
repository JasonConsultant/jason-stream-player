package de.jasonstream.playback.nav

import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Text
import de.jasonstream.playback.ui.OptionSheet
import de.jasonstream.playback.ui.SheetItem
import de.jasonstream.playback.ui.SheetRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Player-Bedienung: Spuren-/Auswahlfenster (▲▼) und Knopfreihe (◀▶ wie die
 * Kopfzeile) – genau ein Schritt je Druck, auch gestaut; gehalten gedrosselt.
 * Mit leanback (TV-Scrollverhalten) wie auf der Box.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w960dp-h540dp-land-television-xhdpi")
@OptIn(ExperimentalFoundationApi::class)
class PlayerNavTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private fun focusedText(): String {
        val n = rule.onAllNodes(isFocused(), useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).lastOrNull()
            ?: return "<none>"
        val out = ArrayList<String>()
        fun walk(x: SemanticsNode) { x.config.getOrNull(SemanticsProperties.Text)?.forEach { out += it.text }; x.children.forEach(::walk) }
        walk(n)
        return out.joinToString("|")
    }

    private fun send(code: Int, action: Int, repeat: Int = 0, t: Long = android.os.SystemClock.uptimeMillis()) =
        rule.runOnUiThread { rule.activity.dispatchKeyEvent(KeyEvent(t, t, action, code, repeat)) }

    private fun frames(n: Int) = repeat(n) { rule.mainClock.advanceTimeByFrame() }

    private fun tap(code: Int) { send(code, KeyEvent.ACTION_DOWN); frames(2); send(code, KeyEvent.ACTION_UP); frames(3) }

    private fun burst(code: Int, n: Int) = rule.runOnUiThread {
        val t = android.os.SystemClock.uptimeMillis()
        repeat(n) {
            rule.activity.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
            rule.activity.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_UP, code, 0))
        }
    }

    private fun hold(code: Int, repeats: Int) {
        val t0 = android.os.SystemClock.uptimeMillis()
        send(code, KeyEvent.ACTION_DOWN, 0, t0)
        frames(25)
        for (r in 1..repeats) { send(code, KeyEvent.ACTION_DOWN, r, t0 + 400 + r * 48L); frames(3) }
        send(code, KeyEvent.ACTION_UP, 0, t0 + 400 + (repeats + 1) * 48L)
        frames(2)
    }

    private fun leanback() = org.robolectric.Shadows.shadowOf(rule.activity.packageManager)
        .setSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK, true)

    @Test fun optionSheetStepsSkipHeadersAndRevealSelected() {
        leanback()
        val rows = buildList {
            add(SheetRow.Header("Tonspur"))
            for (i in 0 until 20) add(SheetRow.Item(SheetItem("Audio $i", selected = i == 15) {}))
            add(SheetRow.Divider)
            add(SheetRow.Header("Untertitel"))
            for (i in 0 until 10) add(SheetRow.Item(SheetItem("Sub $i") {}))
        }
        rule.setContent {
            CompositionLocalProvider(LocalBringIntoViewSpec provides MinimalBringIntoView) {
                Box(Modifier.fillMaxSize().keyGate()) {
                    OptionSheet(rows, Color.Red, androidx.compose.ui.focus.FocusRequester())
                }
            }
        }
        rule.waitForIdle()
        // Einstieg: gewählte Spur (weit unten) ist fokussiert.
        assertEquals("Audio 15", focusedText())
        rule.mainClock.autoAdvance = false
        for (i in 16..19) { tap(KeyEvent.KEYCODE_DPAD_DOWN); assertEquals("Audio $i", focusedText()) }
        // Über Trenner und Überschrift hinweg genau ein Schritt.
        tap(KeyEvent.KEYCODE_DPAD_DOWN); assertEquals("Sub 0", focusedText())
        burst(KeyEvent.KEYCODE_DPAD_DOWN, 5); frames(10)
        assertEquals("Sub 5", focusedText())
        burst(KeyEvent.KEYCODE_DPAD_UP, 7); frames(10)
        assertEquals("Audio 18", focusedText())
        // Gehalten: 10 Wiederholungen à 48 ms → ≤ 1 + 6 Schritte, kein Nachlaufen.
        hold(KeyEvent.KEYCODE_DPAD_UP, 10)
        val after = focusedText()
        frames(20)
        assertEquals(after, focusedText())
        val idx = after.removePrefix("Audio ").toInt()
        assertTrue("hold ended at $after", 18 - idx in 2..7)
        // Ende: ▼ am letzten Eintrag bleibt.
        burst(KeyEvent.KEYCODE_DPAD_DOWN, 40); frames(12)
        assertEquals("Sub 9", focusedText())
        tap(KeyEvent.KEYCODE_DPAD_DOWN); assertEquals("Sub 9", focusedText())
        rule.mainClock.autoAdvance = true
    }

    @Test fun controlRowOneButtonPerPress() {
        leanback()
        val n = 9
        rule.setContent {
            CompositionLocalProvider(LocalBringIntoViewSpec provides MinimalBringIntoView) {
                Box(Modifier.fillMaxSize().keyGate()) {
                    val nav = rememberDpadList(null, n, vertical = false)
                    Row(Modifier.dpadList(nav)) {
                        for (i in 0 until n) {
                            Box(Modifier.padding(4.dp).size(40.dp).then(nav.item(i)).background(Color.Gray).clickable { }) { Text("B$i") }
                        }
                    }
                    LaunchedEffect(Unit) { nav.focus(0) }
                }
            }
        }
        rule.waitForIdle()
        assertEquals("B0", focusedText())
        rule.mainClock.autoAdvance = false
        for (i in 1..5) { tap(KeyEvent.KEYCODE_DPAD_RIGHT); assertEquals("B$i", focusedText()) }
        burst(KeyEvent.KEYCODE_DPAD_LEFT, 3); frames(6)
        assertEquals("B2", focusedText())
        burst(KeyEvent.KEYCODE_DPAD_LEFT, 9); frames(6)
        assertEquals("B0", focusedText())
        hold(KeyEvent.KEYCODE_DPAD_RIGHT, 8)
        val after = focusedText().removePrefix("B").toInt()
        assertTrue("hold → B$after", after in 2..6)
        rule.mainClock.autoAdvance = true
    }
}
