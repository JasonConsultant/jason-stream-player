package de.jasonstream.player.focus

import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.Portal
import de.jasonstream.player.logic.DemoData
import de.jasonstream.player.logic.RawLive
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.state.TestEnv
import de.jasonstream.player.ui.AppRoot
import de.jasonstream.player.ui.FakePlayerFocus
import de.jasonstream.player.ui.PlayerHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import java.util.Calendar

/**
 * Gemeinsame Grundlage der Fokus-Tests: komponiert die ganze App (Demo-Daten,
 * fokussierbarer Platzhalter-Player) und schickt echte Tastendrücke durch
 * `Activity.dispatchKeyEvent` (also wie die Fernbedienung, inkl. Zurück →
 * OnBackPressedDispatcher).
 */
abstract class FocusHarness {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()

    val now: Long = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 21); set(Calendar.MINUTE, 41); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    lateinit var vm: AppViewModel
    val fake = FakePlayerFocus()
    var exits = 0

    /** Großer Datenbestand (viele Gruppen, lange Listen) für Listen-/Scroll-Fälle. */
    fun bigData(): RawLive {
        val cats = (0 until 40).map { Category("g$it", "Gruppe %02d".format(it)) }
        val chans = ArrayList<Channel>()
        for (g in 0 until 40) for (i in 0 until (if (g % 5 == 0) 60 else 12)) {
            chans += Channel("b_${g}_$i", "Sender $g-$i", "g$g", "")
        }
        return RawLive(cats, chans)
    }

    open fun launch(big: Boolean = false, current: String? = "demo_6", setup: (AppViewModel) -> Unit = {}) {
        val env = TestEnv()
        vm = AppViewModel(env, io = Dispatchers.Default, compute = Dispatchers.Default, autoStart = false, clock = { now })
        vm.attach(env.storage)
        val raw = if (big) bigData() else RawLive(DemoData.categories, DemoData.channels)
        runBlocking { vm.setDataForPreview(Portal.demo, raw, if (big) emptyMap() else DemoData.epg(now), current = if (big) "b_7_3" else current) }
        setup(vm)
        rule.setContent {
            androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.testTag("main")) {
                AppRoot(vm, PlayerHost(null, null, fake), onExit = { exits++ }, fixedNow = now)
            }
        }
        settle(6)
    }

    fun settle(rounds: Int = 2) {
        repeat(rounds) {
            rule.waitForIdle()
            rule.mainClock.advanceTimeBy(48)
        }
        rule.waitForIdle()
    }

    fun press(code: Int, settleRounds: Int = 2) {
        rule.runOnUiThread {
            val t = android.os.SystemClock.uptimeMillis()
            rule.activity.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
            rule.activity.dispatchKeyEvent(KeyEvent(t, t + 40, KeyEvent.ACTION_UP, code, 0))
        }
        settle(settleRounds)
    }

    fun left() = press(KeyEvent.KEYCODE_DPAD_LEFT)
    fun right() = press(KeyEvent.KEYCODE_DPAD_RIGHT)
    fun up() = press(KeyEvent.KEYCODE_DPAD_UP)
    fun down() = press(KeyEvent.KEYCODE_DPAD_DOWN)
    fun ok() = press(KeyEvent.KEYCODE_DPAD_CENTER)
    fun back() = press(KeyEvent.KEYCODE_BACK)

    // ------------------------------------------------------------ Abfragen

    fun focusedNodes(): List<SemanticsNode> =
        rule.onAllNodes(isFocused(), useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)

    fun focused(): SemanticsNode? = focusedNodes().lastOrNull()

    fun texts(n: SemanticsNode): List<String> {
        val out = ArrayList<String>()
        fun walk(x: SemanticsNode) {
            x.config.getOrNull(SemanticsProperties.Text)?.forEach { out += it.text }
            x.config.getOrNull(SemanticsProperties.EditableText)?.let { out += it.text }
            x.config.getOrNull(SemanticsProperties.ContentDescription)?.let { out += it }
            x.children.forEach(::walk)
        }
        walk(n)
        return out
    }

    fun label(n: SemanticsNode?): String = n?.let { texts(it).joinToString(" | ").ifEmpty { "#${it.id}" } } ?: "<none>"

    fun tags(n: SemanticsNode): List<String> {
        val out = ArrayList<String>()
        var x: SemanticsNode? = n
        while (x != null) {
            x.config.getOrNull(SemanticsProperties.TestTag)?.let { out += it }
            x = x.parent
        }
        return out
    }

    fun zone(n: SemanticsNode? = focused()): String? = n?.let { tags(it).firstOrNull { t -> t != "main" && t != "player" } }

    /** Fläche des eigenen Fensters (App oder Dialog). */
    fun rootBounds(n: SemanticsNode): Rect {
        var x = n
        while (true) x = x.parent ?: break
        return x.boundsInRoot
    }

    /** Sichtbar = Fläche > 0 und innerhalb des (eigenen) Fensters. */
    fun isVisible(n: SemanticsNode): Boolean {
        val b = n.boundsInRoot
        val r = rootBounds(n)
        if (b.width <= 0.5f || b.height <= 0.5f) return false
        val i = b.intersect(r)
        return i.width > 0.5f && i.height > 0.5f
    }

    /** Texte aller Knoten unter einem Testkennzeichen (z. B. sichtbare Senderliste). */
    fun textsUnder(tag: String): List<String> =
        rule.onAllNodes(androidx.compose.ui.test.hasTestTag(tag), useUnmergedTree = true)
            .fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { texts(it) }
}
