package de.jasonstream.playback.logic

import de.jasonstream.core.model.Episode

/** Folgen-Reihenfolge (vod_meta.dart: episodesInOrder / nextEpisodeOf). */
object NextEpisode {
    fun inOrder(seasons: Map<Int, List<Episode>>): List<Episode> =
        seasons.keys.sorted().flatMap { seasons[it].orEmpty() }

    /** Folge nach [current] – auch über das Staffelende hinweg; null am Ende. */
    fun after(seasons: Map<Int, List<Episode>>, current: Episode): Episode? {
        val all = inOrder(seasons)
        val i = all.indexOfFirst { it.id == current.id }
        if (i < 0 || i + 1 >= all.size) return null
        return all[i + 1]
    }

    /** Ab dieser Restlaufzeit erscheint die Karte (Abspann). */
    const val LEAD_MS = 30_000L
    /** Countdown auf der Karte. */
    const val COUNTDOWN = 10
    /** Kürzere Videos (Trailer, Clips) bekommen keine Karte vor dem Ende. */
    const val MIN_LENGTH_MS = 3 * 60_000L
}

/**
 * Zustand der Karte „Nächste Folge in 10 s“ (Port von next_episode.dart):
 * im Abspann (letzte 30 s) bzw. am Ende auflösen, 10 s Countdown, dann
 * abspielen. OK = jetzt, Zurück = abbrechen (Folge läuft zu Ende, danach
 * schließt der Player).
 */
class NextUpState(private val enabled: () -> Boolean) {
    enum class Phase { idle, resolving, showing, dismissed, done }

    sealed interface Action {
        data object None : Action
        /** Nächste Folge ermitteln (PlayRequest.nextUp aufrufen). */
        data object Resolve : Action
        /** Nächste Folge abspielen. */
        data object Play : Action
        /** Player schließen. */
        data object Exit : Action
    }

    var phase = Phase.idle; private set
    var secondsLeft = NextEpisode.COUNTDOWN; private set
    private var ended = false

    val showing: Boolean get() = phase == Phase.showing

    fun onPosition(posMs: Long, lenMs: Long): Action {
        if (phase != Phase.idle || lenMs < NextEpisode.MIN_LENGTH_MS || posMs <= 0) return Action.None
        if (lenMs - posMs <= NextEpisode.LEAD_MS && enabled()) {
            phase = Phase.resolving
            return Action.Resolve
        }
        return Action.None
    }

    /** Wiedergabe zu Ende. */
    fun onCompleted(): Action {
        ended = true
        return when (phase) {
            Phase.showing -> commit()
            Phase.resolving -> Action.None
            Phase.idle -> if (!enabled()) Action.Exit else {
                phase = Phase.resolving
                Action.Resolve
            }
            Phase.dismissed, Phase.done -> Action.Exit
        }
    }

    /** Ergebnis von nextUp(): [found] = es gibt eine nächste Folge. */
    fun onResolved(found: Boolean): Action {
        if (phase != Phase.resolving) return Action.None
        if (!found) {
            phase = Phase.done
            return if (ended) Action.Exit else Action.None
        }
        phase = Phase.showing
        secondsLeft = NextEpisode.COUNTDOWN
        return Action.None
    }

    /** Sekündlich, solange die Karte sichtbar ist. */
    fun tick(): Action {
        if (phase != Phase.showing) return Action.None
        if (secondsLeft <= 1) return commit()
        secondsLeft--
        return Action.None
    }

    fun commit(): Action {
        if (phase != Phase.showing) return Action.None
        phase = Phase.done
        return Action.Play
    }

    fun cancel(): Action {
        if (phase != Phase.showing) return Action.None
        phase = Phase.dismissed
        return if (ended) Action.Exit else Action.None
    }
}
