package de.jasonstream.player.focus

import android.app.Dialog
import android.view.KeyEvent
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.isFocused
import de.jasonstream.player.logic.ShellNav
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.state.Overlay
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import kotlin.random.Random

/**
 * D-Pad-Crawler: zufällige (feste Saat) Tastenfolgen auf jedem Bildschirm.
 * Nach jedem Tastendruck:
 *  - Fokus vorhanden und sichtbar (auch in Dialogen),
 *  - Zurück beendet die App nur, wenn es vorgesehen ist (zweimal Zurück im
 *    Start-Menü bzw. Willkommen ohne Portal),
 *  - keine Ausnahmen (Compose-Fehler lassen den Test scheitern).
 * Regelmäßig: ▲ (wiederholt) erreicht das obere Menü; am Ende: kein
 * Fokusziel, aus dem keine der vier Pfeiltasten herausführt (Falle).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class DpadCrawlerTest : FocusHarness() {

    private val trace = ArrayDeque<String>()
    private var presses = 0
    private var escapes = 0
    private var dialogsSeen = 0
    private val tabsSeen = HashMap<String, Int>()
    private val zonesSeen = HashMap<String, Int>()
    /** Je Fokusziel: Richtungen ohne Wirkung / mit Wirkung. */
    private val noEffect = HashMap<String, MutableSet<Int>>()
    private val effect = HashMap<String, MutableSet<Int>>()
    private val labels = HashMap<String, String>()

    private val arrows = listOf(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT)

    private fun keyName(k: Int) = when (k) {
        KeyEvent.KEYCODE_DPAD_UP -> "▲"; KeyEvent.KEYCODE_DPAD_DOWN -> "▼"; KeyEvent.KEYCODE_DPAD_LEFT -> "◀"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "▶"; KeyEvent.KEYCODE_DPAD_CENTER -> "OK"; KeyEvent.KEYCODE_BACK -> "BACK"; else -> "$k"
    }

    private fun openDialog(): Dialog? = ShadowDialog.getLatestDialog()?.takeIf { it.isShowing }

    /** Fokussierter Knoten im obersten Fenster (Dialog vor App). */
    private fun top(): SemanticsNode? {
        val all = rule.onAllNodes(isFocused(), useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false)
        val main = all.filter { "main" in tags(it) }
        val other = all - main.toSet()
        return if (openDialog() != null) other.lastOrNull() ?: main.lastOrNull() else main.lastOrNull()
    }

    private fun zoneOf(n: SemanticsNode?): String {
        n ?: return "<none>"
        val t = tags(n)
        if (openDialog() != null && "main" !in t) return "dialog"
        if ("menu" in t) return "menu"
        return t.firstOrNull { it != "main" } ?: "content"
    }

    private fun idOf(n: SemanticsNode?): String = n?.let { "${zoneOf(it)}#${it.id}" } ?: "<none>"

    /** Alle Texte des obersten Fensters (Fingerabdruck: hat die Taste etwas bewirkt?). */
    private fun screenPrint(): Int =
        rule.onAllNodes(androidx.compose.ui.test.hasAnyAncestor(androidx.compose.ui.test.isRoot()) or androidx.compose.ui.test.isRoot(), useUnmergedTree = true)
            .fetchSemanticsNodes(atLeastOneRootRequired = false)
            .sumOf { n -> (n.config.getOrNull(SemanticsProperties.Text)?.joinToString { it.text }?.hashCode() ?: 0) * 31 + n.boundsInRoot.top.toInt() }

    private fun dispatch(code: Int) {
        rule.runOnUiThread {
            val t = android.os.SystemClock.uptimeMillis()
            val d = openDialog()
            val down = KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0)
            val up = KeyEvent(t, t + 40, KeyEvent.ACTION_UP, code, 0)
            if (d != null) { d.dispatchKeyEvent(down); d.dispatchKeyEvent(up) }
            else { rule.activity.dispatchKeyEvent(down); rule.activity.dispatchKeyEvent(up) }
        }
        settle(2)
    }

    private fun describe(): String {
        val f = top()
        val s = vm.shell.value
        return "tab=${s.tab} zone=${s.zone} overlays=${vm.overlays.value.size} dialog=${openDialog() != null} focus=[${zoneOf(f)}] ${label(f).take(90)}"
    }

    private fun failWith(msg: String): Nothing {
        fail("$msg\nnow: ${describe()}\nlast keys:\n" + trace.joinToString("\n"))
        throw IllegalStateException()
    }

    /** Ist ein Zurück an dieser Stelle als „App beenden“ vorgesehen? */
    private fun exitAllowed(): Boolean {
        if (openDialog() != null) return false
        val s = vm.shell.value
        if (vm.overlays.value.isEmpty() && vm.status.value.noPortal) return true
        if (vm.overlays.value.isNotEmpty()) return false
        return ShellNav.back(s, now).effect == ShellNav.Effect.Exit
    }

    private fun step(code: Int) {
        // Gefährliche Bestätigungen (App-Sprache → Activity.recreate) überspringen.
        if (code == KeyEvent.KEYCODE_DPAD_CENTER && openDialog() != null && dangerousDialog()) { step(KeyEvent.KEYCODE_BACK); return }
        val before = top()
        val beforeId = idOf(before)
        val beforePrint = screenPrint()
        val allowed = code == KeyEvent.KEYCODE_BACK && exitAllowed()
        val dialogBefore = openDialog()
        val exitsBefore = exits
        dispatch(code)
        presses++
        // PIN-Abfrage (gesperrter Sender): abbrechen wie mit Zurück.
        vm.pin.value?.let { p -> if (openDialog() == null) { p.result.complete(false); settle() } }
        val after = top()
        val afterId = idOf(after)
        trace.addLast("${keyName(code)}: $beforeId → $afterId  ${label(after).take(70)}")
        if (trace.size > 25) trace.removeFirst()
        tabsSeen.merge(vm.shell.value.tab.name, 1, Int::plus)
        zonesSeen.merge(zoneOf(after), 1, Int::plus)
        if (openDialog() != null) dialogsSeen++

        if (exits != exitsBefore && !allowed) failWith("Back/key exited the app unexpectedly")
        if (code == KeyEvent.KEYCODE_BACK && dialogBefore != null && dialogBefore.isShowing) failWith("Back did not close the dialog")
        if (after == null) failWith("focus lost after ${keyName(code)}")
        // Menü fokussiert ⇔ Shell im Menü (sonst stünde der Fokus in einem unsichtbaren Menü).
        val z = zoneOf(after)
        if (z == "menu" && vm.shell.value.zone != Zone.Menu) failWith("menu focused but shell zone is ${vm.shell.value.zone}")
        if (z != "menu" && z != "dialog" && vm.overlays.value.isEmpty() && !vm.status.value.noPortal && vm.shell.value.zone != Zone.Content) failWith("content focused but shell zone is ${vm.shell.value.zone}")
        if (!isVisible(after)) failWith("focused node not visible after ${keyName(code)}: bounds=${after.boundsInRoot}")
        if (code in arrows) {
            val changed = beforeId != afterId || screenPrint() != beforePrint
            (if (changed) effect else noEffect).getOrPut(beforeId) { HashSet() } += code
            labels[beforeId] = label(before).take(60)
        }
    }

    private fun dangerousDialog(): Boolean {
        val lang = rule.activity.getString(de.jasonstream.core.R.string.languageUserInterface)
        return rule.onAllNodes(androidx.compose.ui.test.hasText(lang), useUnmergedTree = true)
            .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
    }

    private var escapesByBack = 0

    /**
     * Zurück ins obere Menü: zuerst nur mit ▲ (45×), sonst mit Zurück (max. 3×,
     * z. B. tief in einer langen Liste). Beides muss das Menü erreichen.
     */
    private fun escapeToMenu() {
        var guard = 0
        while (openDialog() != null && guard++ < 5) step(KeyEvent.KEYCODE_BACK)
        if (vm.overlays.value.isNotEmpty() || vm.status.value.noPortal) return // Vollbild-Seiten haben kein Menü
        if (zoneOf(top()) == "player") step(KeyEvent.KEYCODE_DPAD_LEFT) // Video → Senderliste
        repeat(45) {
            if (zoneOf(top()) == "menu") { escapes++; return }
            step(KeyEvent.KEYCODE_DPAD_UP)
            if (openDialog() != null) step(KeyEvent.KEYCODE_BACK)
        }
        repeat(3) {
            if (zoneOf(top()) == "menu") { escapesByBack++; return }
            step(KeyEvent.KEYCODE_BACK)
        }
        if (zoneOf(top()) == "menu") { escapesByBack++; return }
        failWith("neither ▲ ×45 nor Back ×3 reached the top menu")
    }

    private var onTarget = 0
    private var resets = 0

    private fun crawl(seed: Int, count: Int = 300, big: Boolean = false, setup: (de.jasonstream.player.state.AppViewModel) -> Unit) {
        launch(big = big, setup = setup)
        if (top() == null) failWith("no initial focus")
        val target = vm.shell.value.tab
        val targetOverlay = vm.overlays.value.lastOrNull()
        val rnd = Random(seed)
        var sinceEscape = 0
        var away = 0
        while (onTarget < count && presses < count * 4) {
            val r = rnd.nextInt(100)
            val code = when {
                zoneOf(top()) == "menu" && r < 55 -> KeyEvent.KEYCODE_DPAD_DOWN // im Menü meist zurück in den Inhalt
                r < 20 -> KeyEvent.KEYCODE_DPAD_UP
                r < 42 -> KeyEvent.KEYCODE_DPAD_DOWN
                r < 61 -> KeyEvent.KEYCODE_DPAD_LEFT
                r < 80 -> KeyEvent.KEYCODE_DPAD_RIGHT
                r < 93 -> KeyEvent.KEYCODE_DPAD_CENTER
                else -> KeyEvent.KEYCODE_BACK
            }
            step(code)
            val here = vm.shell.value.tab == target && vm.overlays.value.lastOrNull() == targetOverlay && !vm.status.value.noPortal
            if (here) { onTarget++; away = 0 } else if (++away > 8) {
                // Zu lange woanders: zurück zum geprüften Bildschirm (wie Auswahl im Menü).
                away = 0; resets++
                if (vm.status.value.noPortal) vm.addDemoPortal()
                while (openDialog() != null) step(KeyEvent.KEYCODE_BACK)
                rule.runOnUiThread {
                    vm.closeOverlays()
                    targetOverlay?.let { vm.pushOverlay(it) }
                    vm.openTab(target)
                }
                settle(4)
                if (top() == null) failWith("no focus after returning to $target")
            }
            // Gelegentlich: Player greift nach dem Fokus (wie der echte Player nach dem Umschalten).
            if (rnd.nextInt(40) == 0) { rule.runOnUiThread { fake.grab() }; settle(); if (top() == null) failWith("focus lost after player grab") }
            if (++sinceEscape >= 45) { sinceEscape = 0; escapeToMenu() }
        }
        escapeToMenu()
        if (onTarget < count) failWith("only $onTarget of $count presses on $target")
        // Fallen: Fokusziele, bei denen jede Pfeiltaste wirkungslos war.
        // (Dialoge ausgenommen: dort sind OK/Zurück der Ausweg, z. B. bei nur einem Eintrag.)
        val traps = noEffect.filter { (id, dirs) -> !id.startsWith("dialog") && dirs.containsAll(arrows) && effect[id].isNullOrEmpty() }.keys
            .map { "$it '${labels[it]}'" }
        println("CRAWL $target${targetOverlay?.let { "/" + it::class.simpleName } ?: ""} seed=$seed presses=$presses onTarget=$onTarget resets=$resets escapes=$escapes/$escapesByBack dialogKeys=$dialogsSeen focusTargets=${(noEffect.keys + effect.keys).size} tabs=$tabsSeen zones=$zonesSeen exits=$exits")
        if (traps.isNotEmpty()) failWith("focus traps (no arrow moves away): $traps")
    }

    @Test fun start() = crawl(11) { it.setShell(ShellState(Tab.Start, Zone.Content)) }
    @Test fun startMenu() = crawl(12) { it.setShell(ShellState(Tab.Start, Zone.Menu)) }
    @Test fun live() = crawl(21) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
    @Test fun liveBig() = crawl(22, big = true) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
    @Test fun guide() = crawl(31) { it.setShell(ShellState(Tab.Guide, Zone.Content)) }
    @Test fun search() = crawl(41) { it.pendingSearch = "sport"; it.setShell(ShellState(Tab.Search, Zone.Content)) }
    @Test fun settings() = crawl(51) { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
    @Test fun portals() = crawl(61, count = 200) { it.setShell(ShellState(Tab.Settings, Zone.Content)); it.pushOverlay(Overlay.Portals) }
}
