package de.jasonstream.player

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.plugin.common.MethodChannel

/**
 * Sprachsuche über die System-Spracheingabe (RecognizerIntent). Die
 * Mikrofon-Berechtigung braucht nur die Erkennungs-App selbst – diese App
 * fordert keine neue Laufzeit-Berechtigung an.
 *
 * Ablauf wie [FileIO]: startActivityForResult, Ergebnis über
 * [onActivityResult]. Antwort: erkannter Text oder null (abgebrochen).
 */
object VoiceSearch {
    const val REQUEST = 4730

    private var pending: MethodChannel.Result? = null

    private fun intent(lang: String?, prompt: String?): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_WEB_SEARCH)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            .apply {
                tag(lang)?.let {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, it)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, it)
                }
                if (!prompt.isNullOrEmpty()) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
            }

    /** App-Sprache (de/en/tr) → BCP-47-Tag für die Erkennung. */
    private fun tag(lang: String?): String? = when (lang) {
        "de" -> "de-DE"
        "en" -> "en-US"
        "tr" -> "tr-TR"
        else -> null
    }

    /** Gibt es eine Activity für ACTION_RECOGNIZE_SPEECH? (braucht <queries>) */
    fun available(activity: Activity): Boolean = try {
        intent(null, null).resolveActivity(activity.packageManager) != null
    } catch (e: Exception) {
        false
    }

    fun start(activity: Activity, lang: String?, prompt: String?, result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent(lang, prompt), REQUEST)
        } catch (e: Exception) {
            pending = null
            result.error("novoice", "Keine Spracheingabe verfügbar", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val r = pending ?: return true
        pending = null
        val text = if (resultCode == Activity.RESULT_OK)
            data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        else null
        r.success(text?.trim()?.takeIf { it.isNotEmpty() })
        return true
    }
}
