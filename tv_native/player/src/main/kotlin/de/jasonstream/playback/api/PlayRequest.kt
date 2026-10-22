package de.jasonstream.playback.api

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Episode
import de.jasonstream.core.model.VodItem
import de.jasonstream.playback.logic.NextEpisode

/** Sendung im Archiv (Catch-up/Replay): Sender + EPG-Eintrag. */
data class CatchupInfo(val channel: Channel, val entry: EpgEntry)

/**
 * Nächste Folge für „Nächste Folge in 10 s“.
 * [season]/[number]/[title] ergeben die Beschriftung „S{0} · F{1} – {2}“.
 * [onStart] läuft, wenn die Folge tatsächlich startet (Verlauf/„Weiterschauen“).
 */
data class NextUp(
    val request: PlayRequest,
    val season: Int,
    val number: Int,
    val title: String,
    val onStart: (() -> Unit)? = null,
)

/**
 * Was der Player abspielen soll (Port von PlayRequest aus models.dart).
 *
 * * LIVE: [channels] + [index] (Zappen in dieser Liste). [url] wird ignoriert –
 *   die Adresse kommt vom Sender (Stalker: [PlayerDeps.resolveLiveUrl]).
 * * CATCHUP: [catchup] (Sender + Sendung); [url] optional (sonst
 *   [PlayerDeps.catchupUrl]). [channels] erlaubt „Zurück zu Live“.
 * * VOD / EPISODE: [url] + [title]; Position wird unter [resumeKey]
 *   gemerkt (gleiche Schlüssel wie die Flutter-App: movie_<id>, ep_<id>,
 *   cu_<senderId>_<startMs>). EPISODE mit [nextUp] zeigt die Karte
 *   „Nächste Folge“.
 *
 * [startPositionMs] > 0 erzwingt eine Startposition (sonst gemerkte Stelle).
 */
data class PlayRequest(
    val portalId: String,
    val channels: List<Channel> = emptyList(),
    val index: Int = 0,
    val kind: Kind,
    val url: String? = null,
    val title: String? = null,
    val startPositionMs: Long = 0,
    val catchup: CatchupInfo? = null,
    /** Zweite Zeile (Jahr · Genre, „S1 · F2 – Titel“, Sendername). */
    val subtitle: String? = null,
    val resumeKey: String? = null,
    /** Hintergrundbild beim Laden (Backdrop/Poster/Standbild). */
    val artworkUrl: String? = null,
    val nextUp: (suspend () -> NextUp?)? = null,
) {
    enum class Kind { LIVE, CATCHUP, VOD, EPISODE }

    val isLive: Boolean get() = kind == Kind.LIVE
    val isReplay: Boolean get() = kind == Kind.CATCHUP

    /** Live: aktueller Sender. Catch-up: Sender der Sendung. */
    val channel: Channel?
        get() = when {
            kind == Kind.CATCHUP -> catchup?.channel
            channels.isEmpty() -> null
            else -> channels[index.coerceIn(0, channels.size - 1)]
        }

    companion object {
        fun live(portalId: String, channels: List<Channel>, index: Int) =
            PlayRequest(portalId, channels, index.coerceIn(0, (channels.size - 1).coerceAtLeast(0)), Kind.LIVE,
                title = channels.getOrNull(index)?.name)

        fun catchup(portalId: String, channel: Channel, entry: EpgEntry, channels: List<Channel> = emptyList(), url: String? = null) =
            PlayRequest(
                portalId, channels, channels.indexOfFirst { it.id == channel.id }.coerceAtLeast(0), Kind.CATCHUP,
                url = url, title = entry.title, subtitle = channel.name,
                catchup = CatchupInfo(channel, entry),
                resumeKey = "cu_${channel.id}_${entry.startMs}",
            )

        fun movie(portalId: String, m: VodItem, subtitle: String? = null) = PlayRequest(
            portalId, kind = Kind.VOD, url = m.streamUrl, title = m.name,
            subtitle = subtitle ?: listOfNotNull(m.year?.toString(), m.genre).joinToString(" · ").ifEmpty { null },
            resumeKey = "movie_${m.id}", artworkUrl = m.backdropUrl ?: m.posterUrl,
        )

        /**
         * Folge einer Serie; mit [seasons] kennt die Anfrage ihre nächste
         * Folge (auch über das Staffelende hinweg), die wiederum ihre nächste kennt.
         * [subtitleOf] formatiert „S{0} · F{1} – {2}“ (übersetzt, aus der App).
         */
        fun episode(
            portalId: String,
            series: VodItem,
            e: Episode,
            seasons: Map<Int, List<Episode>>? = null,
            subtitleOf: (Episode) -> String = { "S${it.season} · F${it.number} – ${it.title}" },
            onStart: ((Episode) -> Unit)? = null,
            onSeriesFinished: (() -> Unit)? = null,
        ): PlayRequest = PlayRequest(
            portalId, kind = Kind.EPISODE, url = e.streamUrl, title = series.name, subtitle = subtitleOf(e),
            resumeKey = "ep_${e.id}", artworkUrl = e.stillUrl ?: series.backdropUrl ?: series.posterUrl,
            nextUp = if (seasons == null) null else {
                {
                    val n = NextEpisode.after(seasons, e)
                    if (n == null) {
                        onSeriesFinished?.invoke()
                        null
                    } else {
                        NextUp(
                            episode(portalId, series, n, seasons, subtitleOf, onStart, onSeriesFinished),
                            n.season, n.number, n.title, onStart = onStart?.let { f -> { f(n) } },
                        )
                    }
                }
            },
        )
    }
}
