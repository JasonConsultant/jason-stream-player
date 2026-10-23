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
    fun bigData(huge: Boolean = false): RawLive {
        val cats = (0 until 40).map { Category("g$it", "Gruppe %02d".format(it)) }
        val chans = ArrayList<Channel>()
        // huge: 40 Gruppen × 50 = 2 000 Sender (schwerer Neuaufbau beim Gruppenwechsel).
        for (g in 0 until 40) for (i in 0 until (if (huge) 50 else if (g % 5 == 0) 60 else 12)) {
            chans += Channel("b_${g}_$i", "Sender $g-$i", "g$g", "")
        }
        return RawLive(cats, chans)
    }

    /**
     * Wie die echte TV-Box: `android.software.leanback` gesetzt. Compose wählt
     * dann für Listen das TV-Scrollverhalten (PivotBringIntoViewSpec) – ohne
     * dieses Merkmal laufen Robolectric-Tests mit dem Handy-Verhalten.
     */
    var leanback = true

    /** Mit big: 2 000 statt ~860 Sender. */
    var huge = false

    open fun launch(big: Boolean = false, current: String? = "demo_6", setup: (AppViewModel) -> Unit = {}) {
        if (leanback) {
            org.robolectric.Shadows.shadowOf(rule.activity.packageManager)
                .setSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK, true)
        }
        val env = TestEnv()
        vm = AppViewModel(env, io = Dispatchers.Default, compute = Dispatchers.Default, autoStart = false, clock = { now })
        vm.attach(env.storage)
        val raw = if (big) bigData(huge) else RawLive(DemoData.categories, DemoData.channels)
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
            dispatchTop(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
            dispatchTop(KeyEvent(t, t + 40, KeyEvent.ACTION_UP, code, 0))
        }
        settle(settleRounds)
    }

    /** Fokussierter Knoten im obersten Fenster (Dialog vor App). */
    fun topFocused(): SemanticsNode? {
        val all = focusedNodes()
        val main = all.filter { "main" in tags(it) }
        val other = all - main.toSet()
        return if (openDialog() != null) other.lastOrNull() ?: main.lastOrNull() else main.lastOrNull()
    }

    // ------------------------------------------------------------ Echtzeit-Tasten
    // Wie auf dem Gerät: Bilder laufen nur, wenn die Uhr weiterläuft (autoAdvance
    // aus) – Tastendrücke können sich also stauen, während die Liste neu aufbaut.

    /** Eine Taste als einzelnes Ereignis (KeyDown mit repeatCount bzw. KeyUp). */
    fun send(code: Int, action: Int, repeat: Int = 0, eventTime: Long = android.os.SystemClock.uptimeMillis()) {
        rule.runOnUiThread { dispatchTop(KeyEvent(eventTime, eventTime, action, code, repeat)) }
    }

    /** Offener Dialog (eigenes Fenster) oder null. */
    fun openDialog(): android.app.Dialog? = org.robolectric.shadows.ShadowDialog.getLatestDialog()?.takeIf { it.isShowing }

    /** Ereignis an das oberste Fenster (Dialog vor App) – wie die Fernbedienung. */
    fun dispatchTop(ev: KeyEvent) {
        val d = openDialog()
        if (d != null) d.dispatchKeyEvent(ev) else rule.activity.dispatchKeyEvent(ev)
    }

    /** n Bilder (16 ms) weiterlaufen lassen. */
    fun frames(n: Int) {
        repeat(n) { rule.mainClock.advanceTimeByFrame() }
    }

    /** Kurzer Druck in Gerätetakt: KeyDown, [holdFrames] Bilder, KeyUp, [gapFrames] Bilder. */
    fun tap(code: Int, holdFrames: Int = 2, gapFrames: Int = 2) {
        send(code, KeyEvent.ACTION_DOWN)
        frames(holdFrames)
        send(code, KeyEvent.ACTION_UP)
        frames(gapFrames)
    }

    /**
     * Taste halten: KeyDown, dann [repeats] Wiederholungen im Abstand von
     * [everyFrames] Bildern (Android: ~50 ms), dann KeyUp.
     */
    fun hold(code: Int, repeats: Int, everyFrames: Int = 3) {
        val t0 = android.os.SystemClock.uptimeMillis()
        send(code, KeyEvent.ACTION_DOWN, 0, t0)
        frames(25) // Android: erste Wiederholung nach ~400 ms
        for (r in 1..repeats) {
            send(code, KeyEvent.ACTION_DOWN, r, t0 + 400 + r * everyFrames * 16L)
            frames(everyFrames)
        }
        send(code, KeyEvent.ACTION_UP, 0, t0 + 400 + (repeats + 1) * everyFrames * 16L)
        frames(2)
    }

    /** Gestaute Ereignisse: alle ohne Bild dazwischen (Liste baut gerade auf). */
    fun burst(code: Int, presses: Int) {
        rule.runOnUiThread {
            val t = android.os.SystemClock.uptimeMillis()
            repeat(presses) {
                dispatchTop(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
                dispatchTop(KeyEvent(t, t + 1, KeyEvent.ACTION_UP, code, 0))
            }
        }
    }

    /** Echtzeit-Modus (keine automatische Uhr), danach [realtimeEnd]. */
    fun realtime() { settle(); rule.mainClock.autoAdvance = false }
    fun realtimeEnd() { rule.mainClock.autoAdvance = true; settle(3) }

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
