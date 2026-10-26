package de.jasonstream.exoplayer

import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Mischt 3–8 Kanäle (16-bit oder Float-PCM) selbst auf Stereo ab, wenn die
 * Ausgabe nur Stereo kann und nicht durchgereicht wird ([Downmix]).
 * Mono/Stereo und andere Formate laufen unverändert durch (inaktiv).
 * [outputChannels] wird bei jedem configure() gefragt (Ausgabe kann wechseln).
 */
@OptIn(UnstableApi::class)
internal class DownmixAudioProcessor(
    private val passthrough: Boolean,
    private val outputChannels: () -> Int,
) : BaseAudioProcessor() {
    private var matrix = FloatArray(0)
    private var inCh = 0
    private val frameIn = FloatArray(8)
    private val frameOut = FloatArray(2)

    /** Für die Stream-Info: zuletzt abgemischte Eingangskanäle (0 = aus). */
    @Volatile
    var activeInputChannels = 0
        private set

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        val enc = inputAudioFormat.encoding
        val ch = inputAudioFormat.channelCount
        val out = try {
            outputChannels()
        } catch (_: Exception) {
            2
        }
        if ((enc != C.ENCODING_PCM_16BIT && enc != C.ENCODING_PCM_FLOAT) ||
            !Downmix.needed(passthrough, ch, out)
        ) {
            activeInputChannels = 0
            return AudioProcessor.AudioFormat.NOT_SET
        }
        matrix = Downmix.matrix(ch)
        inCh = ch
        activeInputChannels = ch
        return AudioProcessor.AudioFormat(inputAudioFormat.sampleRate, 2, enc)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val inFmt = inputAudioFormat
        val start = inputBuffer.position()
        val end = inputBuffer.limit()
        val frames = (end - start) / inFmt.bytesPerFrame
        val out = replaceOutputBuffer(frames * outputAudioFormat.bytesPerFrame)
        // PCM liegt in nativer Byte-Reihenfolge vor; Kopie, damit die
        // Reihenfolge des Aufrufer-Puffers unberührt bleibt.
        val src = inputBuffer.duplicate().order(ByteOrder.nativeOrder())
        val float = inFmt.encoding == C.ENCODING_PCM_FLOAT
        val n = inCh
        val m = matrix
        for (f in 0 until frames) {
            if (float) {
                for (i in 0 until n) frameIn[i] = src.getFloat()
            } else {
                for (i in 0 until n) frameIn[i] = src.getShort() / 32768f
            }
            Downmix.mixFrame(frameIn, n, m, frameOut)
            if (float) {
                out.putFloat(frameOut[0])
                out.putFloat(frameOut[1])
            } else {
                out.putShort(toShort(frameOut[0]))
                out.putShort(toShort(frameOut[1]))
            }
        }
        inputBuffer.position(start + frames * inFmt.bytesPerFrame)
        out.flip()
    }

    private fun toShort(v: Float): Short =
        (v * 32767f).toInt().coerceIn(-32768, 32767).toShort()

    override fun onReset() {
        matrix = FloatArray(0)
        inCh = 0
        activeInputChannels = 0
    }
}

/** Kanalzahl der aktuellen Ton-Ausgabe (Geräteabfrage → [AudioRoute]). */
internal object AudioOutput {
    fun maxChannels(context: Context): Int {
        val am = context.getSystemService(AudioManager::class.java) ?: return 2
        val pm = context.packageManager
        val tv = pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
        val routed = if (Build.VERSION.SDK_INT >= 33) {
            try {
                val attrs = android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
                am.getAudioDevicesForAttributes(attrs).map(::device)
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        val all = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map(::device)
        return AudioRoute.maxChannels(routed, all, tv, hdmiPlugMax(context))
    }

    private fun device(d: AudioDeviceInfo) = AudioRoute.Device(d.type, d.channelCounts)

    private fun hdmiPlugMax(context: Context): Int? = try {
        val filter = IntentFilter(AudioManager.ACTION_HDMI_AUDIO_PLUG)
        val i = if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(null, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(null, filter)
        }
        i?.takeIf { it.getIntExtra(AudioManager.EXTRA_AUDIO_PLUG_STATE, 0) == 1 }
            ?.getIntExtra(AudioManager.EXTRA_MAX_CHANNEL_COUNT, 0)
            ?.takeIf { it > 0 }
    } catch (_: Exception) {
        null
    }
}
