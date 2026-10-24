package de.jasonstream.playback.nav

import android.os.SystemClock
import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlin.math.abs

// ============================================================================
// Pfeiltasten auf dem Fernseher – deterministisch und zählgenau
//
// Gerätemeldung alpha2: „In den Gruppen springt es mehrere Schritte.“ Ursache
// (in LiveStepTest nachgestellt): Wiederholungen beim Halten (repeatCount > 0)
// und gestaute Tastendrücke, während die Liste neu aufbaut, liefen alle durch
// die Standard-Fokussuche – auch mehrere im selben Bild, bevor die Liste
// gescrollt war (dann springt der Fokus aus der Liste). Zusätzlich scrollt
// Compose auf Geräten mit „leanback“ jede Liste bei jedem Schritt (Pivot auf
// 30 %), was mit unserem eigenen Scrollen kollidierte.
//
// alpha4 (Maßnahme 1): Wiederholungen werden nicht mehr verworfen, sondern
// zusammengefasst – jeder Druck zählt den Ziel-Index weiter, gescrollt und
// fokussiert wird höchstens einmal je Bild, immer auf den jüngsten Zielwert.
// Gehaltene Taste = so viele Schritte wie Wiederholungen (wie OwnTV), ohne
// Nachlaufen nach dem Loslassen.
//
//  * [KeyPacer]/[keyGate]: stuft Wiederholungen ein („Bild schon gezeichnet?“);
//    verbraucht nichts mehr, dient dem Tasten-Protokoll (× = zusammengefasst).
//  * [DpadList]: Listen führen ▲▼ (bzw. ◀▶) selbst: Index ±1 je Druck, Ziel
//    sichtbar machen (2 Einträge Abstand zum Rand, nur wenn nötig), dann Fokus
//    per eigenem FocusRequester – je Bild nur für den letzten Zielwert.
//  * [MinimalBringIntoView]: nur scrollen, wenn ein fokussiertes Element nicht
//    mit einer Zeile Vorlauf sichtbar ist (statt TV-Pivot); der Vorlauf hält
//    die nächste Zeile komponiert, damit die Standard-Fokussuche beim Halten
//    nicht am Rand „ausläuft“ (Maßnahme 5).
//  * [focusTrap]: Fokus kann eine Liste in ▲▼-Richtung (Dialoge: gar nicht)
//    nicht verlassen, wenn die Fokussuche ins Leere liefe (Maßnahme 2).
// ============================================================================

/** Pfeil-/Kanaltasten, die gedrosselt werden. */
fun isStepKey(code: Int) = when (code) {
    AndroidKeyEvent.KEYCODE_DPAD_UP, AndroidKeyEvent.KEYCODE_DPAD_DOWN,
    AndroidKeyEvent.KEYCODE_DPAD_LEFT, AndroidKeyEvent.KEYCODE_DPAD_RIGHT,
    AndroidKeyEvent.KEYCODE_CHANNEL_UP, AndroidKeyEvent.KEYCODE_CHANNEL_DOWN,
    AndroidKeyEvent.KEYCODE_PAGE_UP, AndroidKeyEvent.KEYCODE_PAGE_DOWN,
    -> true
    else -> false
}

/**
 * Einstufung gehaltener Tasten. Reine Logik (ohne Compose), damit sie auch
 * im Player-Modul und in einfachen Tests nutzbar ist.
 *
 * [accept] = „diesen Schritt sofort zeichnen?“: true bei neuem Druck (repeatCount
 * 0 oder andere Taste) und bei Wiederholungen, wenn seit dem letzten gezeichneten
 * Schritt ein Bild fertig ist ([frameBusy] false), die Wiederholung nicht
 * veraltet ist (älter als [staleMs]: gestaut, weil die App beschäftigt war) und
 * [minIntervalMs] vergangen sind. false heißt nur „zusammenfassen“ – der Schritt
 * zählt trotzdem (siehe [DpadList]), verworfen wird nichts.
 */
class KeyPacer(
    private val minIntervalMs: Long = 0,
    private val staleMs: Long = 150,
    private val clock: () -> Long = { SystemClock.uptimeMillis() },
) {
    /** Seit dem letzten gezeichneten Schritt noch kein Bild fertig. */
    var frameBusy = false
    private var lastAt = Long.MIN_VALUE / 4
    private var lastCode = 0

    fun accept(code: Int, repeatCount: Int, eventTime: Long): Boolean {
        if (repeatCount == 0 || code != lastCode) {
            lastCode = code
            lastAt = eventTime
            frameBusy = true
            return true
        }
        if (clock() - eventTime > staleMs) return false
        if (frameBusy) return false
        if (eventTime - lastAt < minIntervalMs) return false
        lastAt = eventTime
        frameBusy = true
        return true
    }
}

/**
 * Wurzel-Modifier („Tasten-Tor“): stuft gehaltene Pfeiltasten ein und meldet
 * sie dem Protokoll ([onEvent]: Ereignis, zusammengefasst?). Verbraucht keine
 * Tasten – jeder Druck erreicht die Liste und zählt dort einen Schritt.
 */
@Composable
fun Modifier.keyGate(onEvent: ((android.view.KeyEvent, Boolean) -> Unit)? = null): Modifier {
    val scope = rememberCoroutineScope()
    val pacer = remember { KeyPacer() }
    return this.onPreviewKeyEvent { ev ->
        val n = ev.nativeKeyEvent
        if (ev.type != KeyEventType.KeyDown || !isStepKey(n.keyCode)) {
            onEvent?.invoke(n, false)
            return@onPreviewKeyEvent false
        }
        val render = pacer.accept(n.keyCode, n.repeatCount, n.eventTime)
        onEvent?.invoke(n, !render)
        if (render) scope.launch { withFrameNanos { }; pacer.frameBusy = false }
        false
    }
}

/**
 * Fokusfalle (Maßnahme 2): Verlässt die Fokussuche diesen Bereich in einer der
 * [directions], bleibt der Fokus stehen (präventiv, statt ihn nachträglich
 * zurückzuholen). Programmgesteuerte Wechsel (requestFocus) sind nicht betroffen.
 * [all]: alle Richtungen (Dialoge).
 */
fun Modifier.focusTrap(all: Boolean = false): Modifier = this.focusProperties {
    onExit = {
        val d = requestedFocusDirection
        if (all || d == FocusDirection.Up || d == FocusDirection.Down) {
            if (d != FocusDirection.Enter && d != FocusDirection.Exit) cancelFocusChange()
        }
    }
}

/**
 * Nur scrollen, wenn das Element nicht mit einer Zeile Vorlauf sichtbar ist
 * (kein TV-Pivot bei jedem Schritt). Vorlauf = eine Elementhöhe, höchstens der
 * halbe Rest des Fensters – so ist der nächste Eintrag schon komponiert, wenn
 * die gehaltene Taste ihn fokussieren will.
 */
object MinimalBringIntoView : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val trailing = offset + size
        if (size >= containerSize) {
            // Größer als das Fenster: Anfang bündig, sonst nicht bewegen.
            return if (offset > 0f) offset else if (trailing < containerSize) trailing - containerSize else 0f
        }
        val room = minOf(size, (containerSize - size) / 2f).coerceAtLeast(0f)
        return when {
            offset >= room && trailing <= containerSize - room -> 0f
            offset < room -> offset - room
            else -> trailing + room - containerSize
        }
    }
}

/**
 * Liste mit eigener Pfeiltasten-Führung. [index] ist der Merker der
 * Fokusposition (kein Compose-Zustand → keine Neukomposition je Schritt).
 *
 * Einträge hängen sich mit [item] an; die Liste selbst bekommt [keys]
 * (onPreviewKeyEvent). Slots können auf Lazy-Indizes abgebildet werden
 * ([lazyIndexOf], z. B. Einstellungen mit Überschriften dazwischen).
 */
@Stable
class DpadList internal constructor(
    private val scope: CoroutineScope,
    val lazy: LazyListState?,
    val vertical: Boolean,
    private val margin: Int,
) {
    /** Anzahl fokussierbarer Einträge (bei jeder Komposition gesetzt). */
    var count = 0
    /** Fokussierter bzw. Ziel-Eintrag. */
    var index = 0
    /** Fokus liegt gerade in der Liste. */
    var hasFocus = false
        private set
    var lazyIndexOf: (Int) -> Int = { it }
    /** Eigene Fokus-Anforderung je Slot (z. B. Zeilen der Startseite: deren eigene Liste). */
    var requestSlot: ((Int) -> Boolean)? = null

    private val reqs = HashMap<Int, FocusRequester>()
    private val prevKey = if (vertical) AndroidKeyEvent.KEYCODE_DPAD_UP else AndroidKeyEvent.KEYCODE_DPAD_LEFT
    private val nextKey = if (vertical) AndroidKeyEvent.KEYCODE_DPAD_DOWN else AndroidKeyEvent.KEYCODE_DPAD_RIGHT
    private var moveSeq = 0

    fun requester(i: Int): FocusRequester = reqs.getOrPut(i) { FocusRequester() }

    /** Modifier für Eintrag [i] (vor tvClick/focusable anwenden). */
    fun item(i: Int): Modifier = Modifier.focusRequester(requester(i)).onFocusChanged {
        if (it.hasFocus) index = i
    }

    /** Modifier für die Liste: Fokus-Merker. */
    fun container(): Modifier = Modifier.onFocusChanged { hasFocus = it.hasFocus }

    /** Richtung der Taste (−1/+1) oder 0, wenn sie nicht zu dieser Liste gehört. */
    fun dirOf(code: Int) = when (code) { prevKey -> -1; nextKey -> 1; else -> 0 }

    /**
     * Taste behandeln. [onEdge] wird am Anfang/Ende gerufen (true = erledigt,
     * false = Standard-Fokussuche darf weiter, z. B. hinauf ins Menü).
     * Jeder KeyDown (auch Wiederholungen, auch gestaute) zählt einen Schritt;
     * gezeichnet wird je Bild nur der jüngste Zielwert.
     */
    fun onKey(ev: KeyEvent, onEdge: (Int) -> Boolean = { true }): Boolean {
        val dir = dirOf(ev.nativeKeyEvent.keyCode)
        if (dir == 0) return false
        if (ev.type == KeyEventType.KeyUp) return true
        if (ev.type != KeyEventType.KeyDown) return false
        val n = count
        val cur = if (n > 0) index.coerceIn(0, n - 1) else 0
        val t = cur + dir
        if (n <= 0 || t < 0 || t >= n) {
            // Rand: ausstehenden Schritt sofort zeichnen (Fokus auf den Ziel-Index), danach
            // keine Nachversuche mehr – onEdge darf den Fokus woandershin geben.
            if (deferred) { reveal(index); moveSeq++ }
            return onEdge(dir)
        }
        index = t
        step(t)
        return true
    }

    /** Fokus auf Eintrag [i] (scrollt nur, wenn nötig). */
    fun focus(i: Int = index) {
        val n = count
        if (n <= 0) return
        index = i.coerceIn(0, n - 1)
        reveal(index)
    }

    private fun tryRequest(i: Int): Boolean {
        requestSlot?.let { return it(i) }
        return runCatching { requester(i).requestFocus() }.getOrDefault(false)
    }

    /** In diesem Bild schon gescrollt/fokussiert. */
    private var frameRendered = false
    /** Ein Schritt wartet auf das nächste Bild. */
    private var deferred = false

    private fun step(t: Int) {
        if (frameRendered) { deferred = true; return }
        reveal(t)
    }

    private fun reveal(t: Int) {
        val seq = ++moveSeq
        val st = lazy
        deferred = false
        frameRendered = true
        // UNDISPATCHED: Scrollen + Fokus laufen sofort im Tastendruck (scrollToItem/
        // scrollBy messen synchron neu) – kein Bild Verzögerung, kein Stau.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            if (st != null) runCatching { revealInList(st, lazyIndexOf(t), margin) }
            if (tryRequest(t)) return@launch
            repeat(6) {
                withFrameNanos { }
                if (seq != moveSeq) return@launch
                if (tryRequest(t)) return@launch
            }
        }
        // Nächstes Bild: weitere Drücke, die inzwischen kamen, als einen Schritt zeichnen.
        scope.launch {
            withFrameNanos { }
            frameRendered = false
            if (deferred) reveal(index)
        }
    }

    companion object {
        /**
         * Lazy-Eintrag [li] mit [margin] Einträgen Abstand zum Rand sichtbar
         * machen – minimal: ist er schon gut sichtbar, wird nicht gescrollt.
         */
        suspend fun revealInList(st: LazyListState, li: Int, margin: Int) {
            val info = st.layoutInfo
            val total = info.totalItemsCount
            val vis = info.visibleItemsInfo
            if (total == 0) return
            if (vis.isEmpty()) { st.scrollToItem((li - margin).coerceAtLeast(0)); return }
            val end = info.viewportEndOffset - info.afterContentPadding
            val fully = vis.count { it.offset >= 0 && it.offset + it.size <= end }
            val m = minOf(margin, ((fully - 1) / 2).coerceAtLeast(0))
            val lo = (li - m).coerceAtLeast(0)
            val hi = (li + m).coerceAtMost(total - 1)
            val loI = vis.firstOrNull { it.index == lo }
            val hiI = vis.firstOrNull { it.index == hi }
            val topOk = loI != null && loI.offset >= 0
            val botOk = hiI != null && hiI.offset + hiI.size <= end
            if (topOk && botOk) return
            if (!topOk && (loI != null || lo < vis.first().index)) {
                st.scrollToItem(lo)
                return
            }
            if (!botOk) {
                if (hiI != null) {
                    st.scrollBy((hiI.offset + hiI.size - end).toFloat())
                } else {
                    val first = vis.first()
                    val last = vis.last()
                    if (hi > last.index) {
                        val step = if (vis.size > 1) (last.offset - first.offset).toFloat() / (vis.size - 1) else last.size.toFloat()
                        st.scrollBy((last.offset + last.size - end) + (hi - last.index) * step)
                    } else {
                        st.scrollToItem(lo)
                    }
                }
            }
        }
    }
}

/** Liste mit eigener Pfeiltasten-Führung (siehe [DpadList]). */
@Composable
fun rememberDpadList(lazy: LazyListState?, count: Int, vertical: Boolean = true, margin: Int = 2): DpadList {
    val scope = rememberCoroutineScope()
    val nav = remember(lazy, vertical) { DpadList(scope, lazy, vertical, margin) }
    nav.count = count
    return nav
}

/** Liste: Pfeiltasten dieser Achse selbst führen. */
fun Modifier.dpadList(nav: DpadList, onEdge: (Int) -> Boolean = { true }): Modifier =
    this.then(nav.container()).onPreviewKeyEvent { nav.onKey(it, onEdge) }

