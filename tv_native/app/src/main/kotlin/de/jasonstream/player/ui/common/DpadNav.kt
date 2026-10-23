package de.jasonstream.player.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import de.jasonstream.playback.nav.dpadList as navDpadList
import de.jasonstream.playback.nav.keyGate as navKeyGate

// Die Pfeiltasten-Führung liegt im Modul :player (de.jasonstream.playback.nav),
// damit Player-Bedienung und App dieselbe Logik nutzen. Hier: App-Anbindung.

typealias DpadList = de.jasonstream.playback.nav.DpadList
typealias KeyPacer = de.jasonstream.playback.nav.KeyPacer

val MinimalBringIntoView = de.jasonstream.playback.nav.MinimalBringIntoView

@Composable
fun rememberDpadList(lazy: androidx.compose.foundation.lazy.LazyListState?, count: Int, vertical: Boolean = true, margin: Int = 2): DpadList =
    de.jasonstream.playback.nav.rememberDpadList(lazy, count, vertical, margin)

fun Modifier.dpadList(nav: DpadList, onEdge: (Int) -> Boolean = { true }): Modifier =
    this.navDpadList(nav, onEdge)

/** Tasten-Tor der App (+ Tasten-Protokoll). */
@Composable
fun Modifier.keyGate(): Modifier = navKeyGate { ev, dropped -> KeyLog.record(ev, dropped) }

// ---------------------------------------------------------------- Diagnose

/**
 * Zähler für Neukompositionen (Tests: „ganzer Bildschirm je Taste?“).
 * Aus = keine Arbeit in der App.
 */
object RecomposeProbe {
    @JvmField var enabled = false
    val counts = HashMap<String, Int>()
    fun reset() = counts.clear()
    operator fun get(name: String) = counts[name] ?: 0
}

/**
 * In einem Composable aufrufen: zählt dessen (erfolgreiche) Kompositionen.
 * Nicht überspringbar (sonst würde der Aufruf mit gleichem Namen ausgelassen).
 */
@Composable
@androidx.compose.runtime.NonRestartableComposable
fun probe(name: String) {
    if (!RecomposeProbe.enabled) return
    SideEffect { RecomposeProbe.counts[name] = (RecomposeProbe.counts[name] ?: 0) + 1 }
}
