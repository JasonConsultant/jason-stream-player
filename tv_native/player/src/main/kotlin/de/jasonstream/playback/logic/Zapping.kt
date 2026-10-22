package de.jasonstream.playback.logic

import de.jasonstream.core.model.Channel
import de.jasonstream.data.channels.VariantIndex

/** Zyklischer Index (−1 → letzter Sender). */
fun wrapIndex(i: Int, n: Int): Int = if (n <= 0) 0 else ((i % n) + n) % n

/**
 * Zapping-Leiste (Port der Leisten-Logik aus player_screen.dart):
 * sichtbar 4 s, zeigt den laufenden oder einen geblätterten Sender
 * (Vorschau). OK schaltet auf den gezeigten, Zurück/Zeitablauf schließt.
 */
class ZapBarState {
    var visible = false; private set
    var index = 0; private set

    fun isPreview(current: Int, n: Int) = visible && wrapIndex(index, n) != current

    /** Leiste für [at] (Standard: laufender Sender) zeigen. */
    fun show(at: Int, n: Int) {
        visible = true
        index = wrapIndex(at, n)
    }

    /** ◀▶ blättern. */
    fun browse(dir: Int, current: Int, n: Int) = show((if (visible) index else current) + dir, n)

    fun hide(current: Int) {
        visible = false
        index = current
    }

    /** OK: Ziel-Index zum Umschalten oder null (gezeigter = laufender). */
    fun confirm(current: Int, n: Int): Int? {
        val t = wrapIndex(index, n)
        return if (t != current) t else null
    }
}

/** Ergebnis der Direktwahl. */
sealed interface DigitResult {
    /** Sender in der aktuellen Liste (Index). */
    data class InList(val index: Int) : DigitResult
    /** Sender in einer anderen Liste (alle sichtbaren Sender). */
    data class InOther(val list: List<Channel>, val index: Int) : DigitResult
    data class NotFound(val number: Int) : DigitResult
    data object Empty : DigitResult
}

/**
 * Direktwahl per Zifferntasten: bis zu 4 Ziffern (die älteste fällt
 * heraus), nach 1,5 s ohne Eingabe oder mit OK ausführen.
 */
class DigitEntry {
    companion object {
        const val TIMEOUT_MS = 1500L
        const val MAX_DIGITS = 4
    }

    var digits: String = ""; private set

    fun push(d: Int): String {
        require(d in 0..9)
        val next = digits + d
        digits = if (next.length > MAX_DIGITS) next.substring(1) else next
        return digits
    }

    fun clear() { digits = "" }

    /**
     * Ausführen: Sender mit dieser Nummer in [current], sonst in [all];
     * Nummer einer zusammengefassten Variante → deren sichtbarer Vertreter.
     */
    fun commit(
        current: List<Channel>,
        all: List<Channel> = emptyList(),
        raw: List<Channel> = emptyList(),
        variants: VariantIndex = VariantIndex.empty,
    ): DigitResult {
        val typed = digits
        digits = ""
        if (typed.isEmpty()) return DigitResult.Empty
        val n = typed.toIntOrNull() ?: return DigitResult.NotFound(-1)
        val i = current.indexOfFirst { it.number == n }
        if (i >= 0) return DigitResult.InList(i)
        var j = all.indexOfFirst { it.number == n }
        if (j < 0) {
            val hidden = raw.firstOrNull { it.number == n }
            if (hidden != null) {
                val rep = variants.representativeOf(hidden.id)
                val k = current.indexOfFirst { it.id == rep }
                if (k >= 0) return DigitResult.InList(k)
                j = all.indexOfFirst { it.id == rep }
            }
        }
        if (j >= 0) return DigitResult.InOther(all, j)
        return DigitResult.NotFound(n)
    }
}

/** Darf die Wiedergabestelle gemerkt werden? (canSaveResume aus player_screen.dart) */
fun canSaveResume(live: Boolean, opening: Boolean, posSec: Long, totalSec: Long): Boolean =
    !live && !opening && posSec >= 5 && totalSec > 0

/** Gemerkte Stelle nur ab 15 s anspringen (wie die Flutter-App). */
fun resumeTargetMs(saved: Pair<Int, Int>?): Long? {
    val pos = saved?.first ?: return null
    return if (pos > 15) pos * 1000L else null
}

/** Schlaf-Timer-Stufen in Minuten (0 = Aus). */
val sleepChoicesMin = listOf(0, 15, 30, 45, 60, 90, 120)
