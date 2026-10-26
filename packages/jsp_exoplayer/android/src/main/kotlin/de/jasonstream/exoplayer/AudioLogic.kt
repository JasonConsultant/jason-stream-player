package de.jasonstream.exoplayer

import kotlin.math.abs
import kotlin.math.tanh

/**
 * Reine Ton-Logik (JVM-Tests): Wiedergabe-Geschwindigkeit, AudioTrack-Puffer,
 * Stereo-Abmischung von Mehrkanal-Ton.
 */

/**
 * Wiedergabe-Geschwindigkeit. Immer 1.0: Media3 hält Live-Streams sonst mit
 * 0,97…1,03-facher Geschwindigkeit am Live-Rand – der Ton wird dabei per
 * Sonic zeitgestreckt und klingt „eiernd/blechern“ (Ursache in 2.3.0).
 * Bei Hängern springt Media3 ohnehin selbst an den Live-Rand (BEHIND_LIVE_WINDOW).
 */
object PlaybackSpeed {
    const val NORMAL = 1.0f
    const val LIVE_MIN = 1.0f
    const val LIVE_MAX = 1.0f
}

/**
 * AudioTrack-Puffer für PCM. Media3-Vorgabe: 250–750 ms (4 × Mindestpuffer
 * des Geräts). Schwache TV-Boxen geraten bei Bild-Dekodierung über die
 * Flutter-Textur, GC oder FFmpeg-Ton gelegentlich mit dem Nachfüllen in
 * Verzug → Unterlauf = Knacksen. 500–1000 ms überbrücken solche Lücken; die
 * A/V-Synchronisation bleibt (Media3 rechnet die Puffer-Latenz heraus), nur
 * Pause/Lautstärke greifen um Bruchteile einer Sekunde später – unhörbar.
 */
object AudioBufferPlan {
    const val MIN_PCM_US = 500_000
    const val MAX_PCM_US = 1_000_000
    const val MULTIPLIER = 4
}

/**
 * Eigene Stereo-Abmischung (ITU-R BS.775 / Dolby Lo/Ro): Center und Surround
 * mit −3 dB, LFE verworfen, jede Zeile auf Summe 1 normiert (kann nicht
 * übersteuern). Danach +3 dB Ausgleich mit weichem Limiter (kein hartes
 * Clipping). Androids eigene Abmischung (AudioFlinger) addiert ohne
 * Normierung und schneidet hart ab → „knistert/verzerrt“ bei lauten Szenen.
 *
 * Kanalreihenfolge wie AudioTrack (Media3 Util.getAudioTrackChannelConfig):
 * 1 = M; 2 = FL FR; 3 = FL FR FC; 4 = FL FR BL BR; 5 = FL FR FC BL BR;
 * 6 = FL FR FC LFE BL BR; 7 = FL FR FC LFE BL BR BC; 8 = FL FR FC LFE BL BR SL SR.
 */
object Downmix {
    const val MINUS_3DB = 0.70710677f
    const val MINUS_6DB = 0.5f

    /** +3 dB Ausgleich nach der Normierung (sonst deutlich leiser als Stereo-Quellen). */
    const val MAKEUP_GAIN = 1.4125376f

    /** Ab hier (≈ −2,5 dBFS) setzt der weiche Limiter ein. */
    const val KNEE = 0.75f

    /** Abmischen? Nur ohne Durchreichen, bei 3–8 Eingangskanälen und Stereo-Ausgabe. */
    fun needed(passthrough: Boolean, inputChannels: Int, outputChannels: Int): Boolean =
        !passthrough && inputChannels in 3..8 && outputChannels <= 2

    private const val A = MINUS_3DB
    private const val H = MINUS_6DB

    /** Rohe Koeffizienten (L-Zeile, R-Zeile) je Eingangskanal. */
    private fun raw(ch: Int): Pair<FloatArray, FloatArray> = when (ch) {
        1 -> floatArrayOf(1f) to floatArrayOf(1f)
        2 -> floatArrayOf(1f, 0f) to floatArrayOf(0f, 1f)
        3 -> floatArrayOf(1f, 0f, A) to floatArrayOf(0f, 1f, A)
        4 -> floatArrayOf(1f, 0f, A, 0f) to floatArrayOf(0f, 1f, 0f, A)
        5 -> floatArrayOf(1f, 0f, A, A, 0f) to floatArrayOf(0f, 1f, A, 0f, A)
        6 -> floatArrayOf(1f, 0f, A, 0f, A, 0f) to floatArrayOf(0f, 1f, A, 0f, 0f, A)
        7 -> floatArrayOf(1f, 0f, A, 0f, A, 0f, H) to floatArrayOf(0f, 1f, A, 0f, 0f, A, H)
        8 -> floatArrayOf(1f, 0f, A, 0f, A, 0f, A, 0f) to floatArrayOf(0f, 1f, A, 0f, 0f, A, 0f, A)
        else -> throw IllegalArgumentException("channels $ch")
    }

    private val cache: Array<FloatArray> = Array(8) { i -> build(i + 1) }

    private fun build(ch: Int): FloatArray {
        val (l, r) = raw(ch)
        val out = FloatArray(2 * ch)
        val sl = l.sum()
        val sr = r.sum()
        for (i in 0 until ch) {
            out[i] = l[i] / sl
            out[ch + i] = r[i] / sr
        }
        return out
    }

    /**
     * Matrix für [channels] Eingangskanäle → Stereo, zeilenweise:
     * `m[o * channels + i]` (o = 0 links, 1 rechts). Für 1–8 Kanäle.
     */
    fun matrix(channels: Int): FloatArray {
        require(channels in 1..8) { "channels $channels" }
        return cache[channels - 1]
    }

    /** Weicher Limiter: linear bis [KNEE], darüber tanh-Knie, Betrag immer < 1. */
    fun softClip(x: Float): Float {
        val a = abs(x)
        if (a <= KNEE) return x
        val y = KNEE + (1f - KNEE) * tanh(((a - KNEE) / (1f - KNEE)).toDouble()).toFloat()
        return if (x < 0) -y else y
    }

    /** Ein Frame (Werte −1…1) abmischen: [out] bekommt L/R. */
    fun mixFrame(input: FloatArray, channels: Int, m: FloatArray, out: FloatArray) {
        var l = 0f
        var r = 0f
        for (i in 0 until channels) {
            val s = input[i]
            l += m[i] * s
            r += m[channels + i] * s
        }
        out[0] = softClip(l * MAKEUP_GAIN)
        out[1] = softClip(r * MAKEUP_GAIN)
    }
}

/** Wie viele Kanäle kann die Ton-Ausgabe? (rein; die Geräteliste liefert [AudioOutput]). */
object AudioRoute {
    // AudioDeviceInfo.TYPE_* (Werte fest im Android-SDK).
    const val TYPE_HDMI = 9
    const val TYPE_HDMI_ARC = 10
    const val TYPE_USB_DEVICE = 11
    const val TYPE_HDMI_EARC = 29

    private val multichannel = setOf(TYPE_HDMI, TYPE_HDMI_ARC, TYPE_HDMI_EARC, TYPE_USB_DEVICE)

    /** Gerät mit Typ und gemeldeten Kanalzahlen (leer = unbekannt). */
    data class Device(val type: Int, val channelCounts: IntArray)

    /**
     * [routed]: Ausgabegeräte für Medien (API 33+, sonst null). [all]: alle
     * Ausgabegeräte. [tv]: Fernseher/Box. [hdmiPlugMax]: Kanalzahl aus dem
     * HDMI-Audio-Ereignis (null = unbekannt).
     * Handy: Lautsprecher/Kopfhörer/Bluetooth = Stereo. TV: HDMI mit
     * Mehrkanal-PCM (AVR) → dessen Kanalzahl, sonst Stereo.
     */
    fun maxChannels(routed: List<Device>?, all: List<Device>, tv: Boolean, hdmiPlugMax: Int?): Int {
        fun of(d: Device): Int {
            if (d.type !in multichannel) return 2
            if (d.channelCounts.isNotEmpty()) return d.channelCounts.max()
            return hdmiPlugMax ?: 2
        }
        if (!routed.isNullOrEmpty()) return routed.maxOf { of(it) }.coerceAtLeast(1)
        if (!tv) return 2
        val hdmi = all.filter { it.type in multichannel }
        if (hdmi.isEmpty()) return 2
        return hdmi.maxOf { of(it) }.coerceAtLeast(1)
    }
}
