package de.jasonstream.player.logic

/** Bereiche der Oberfläche (oberes Menü). */
enum class Tab { Start, Live, Guide, Movies, Series, Search, Settings }

/** Wo der Fokus gerade ist: oberes Menü oder Inhalt. */
enum class Zone { Menu, Content }

data class ShellState(
    val tab: Tab = Tab.Start,
    val zone: Zone = Zone.Content,
    /** Zeitpunkt des ersten „Zurück“ auf der Startseite (für Beenden). */
    val exitArmedAt: Long? = null,
)

/**
 * Zurück-Logik der TV-Oberfläche:
 * Inhalt → Menü → Start → „Zum Beenden nochmal Zurück drücken“ (2 s).
 * Bildschirme mit eigenem Zustand (Overlay, Dialog) verbrauchen „Zurück“
 * vorher selbst.
 */
object ShellNav {
    const val EXIT_WINDOW_MS = 2000L

    enum class Effect { None, ShowExitHint, Exit }

    data class Result(val state: ShellState, val effect: Effect = Effect.None)

    fun back(s: ShellState, now: Long): Result = when {
        s.zone == Zone.Content -> Result(s.copy(zone = Zone.Menu, exitArmedAt = null))
        s.tab != Tab.Start -> Result(s.copy(tab = Tab.Start, exitArmedAt = null))
        s.exitArmedAt != null && now - s.exitArmedAt <= EXIT_WINDOW_MS -> Result(s, Effect.Exit)
        else -> Result(s.copy(exitArmedAt = now), Effect.ShowExitHint)
    }

    /** Tab im Menü gewählt (Fokus bleibt im Menü). */
    fun select(s: ShellState, tab: Tab) = s.copy(tab = tab, zone = Zone.Menu, exitArmedAt = null)

    /** ▼ aus dem Menü / OK auf einem Tab. */
    fun enterContent(s: ShellState) = s.copy(zone = Zone.Content, exitArmedAt = null)

    /** ▲ aus der obersten Inhaltszeile. */
    fun toMenu(s: ShellState) = s.copy(zone = Zone.Menu, exitArmedAt = null)

    /** Direkt zu einem Bereich mit Fokus im Inhalt (z. B. „Ansehen“ → Live TV). */
    fun open(s: ShellState, tab: Tab) = s.copy(tab = tab, zone = Zone.Content, exitArmedAt = null)
}
