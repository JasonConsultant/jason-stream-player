package de.jasonstream.playback

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.api.PlayerDeps
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.playback.ui.PlayerContent

/**
 * Vollbild-Player (Port von lib/ui/player/player_screen.dart).
 *
 * @param request was gespielt wird. Ändert die App die Anfrage (z. B. Auswahl
 *   in ihrer Senderliste), schaltet der Player mit derselben Engine um.
 * @param deps Zugriff auf Speicher, EPG, Varianten, Favoriten, PIN, Aufnahme.
 * @param onExit Player schließen (Zurück, Ende eines Films, Schlaf-Timer).
 * @param onOpenGuide Blau / Guide-Taste: TV-Guide der App öffnen.
 * @param onOpenChannelList ◀ (Leiste aus) bzw. Listen-Knopf: Senderliste der
 *   App über dem Player öffnen. Die Wiedergabe läuft weiter; die Auswahl
 *   kommt als neue [request] zurück.
 * @param engine eigene Engine (z. B. in der Activity gehalten); null = der
 *   Player legt eine an und gibt sie beim Verlassen frei.
 * @param onRequestChanged meldet den tatsächlich laufenden Stand nach
 *   internem Zappen/Replay/nächster Folge (für Markierung in Listen und
 *   „letzter Sender“).
 * @param keepPlayingOnExit nur mit eigener [engine]: beim Verlassen nicht
 *   stoppen (z. B. Weiterlaufen im Mini-Bild des TV-Guides). Dann muss die
 *   App selbst `engine.stop()` aufrufen, wenn nichts mehr gezeigt wird.
 */
@Composable
fun PlayerScreen(
    request: PlayRequest,
    deps: PlayerDeps,
    onExit: () -> Unit,
    onOpenGuide: () -> Unit,
    onOpenChannelList: () -> Unit,
    modifier: Modifier = Modifier,
    engine: PlayerEngine? = null,
    onRequestChanged: ((PlayRequest) -> Unit)? = null,
    keepPlayingOnExit: Boolean = false,
) {
    PlayerContent(request, deps, onExit, onOpenGuide, onOpenChannelList, modifier, engine, onRequestChanged, keepPlayingOnExit)
}
