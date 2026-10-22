package de.jasonstream.player.logic

import android.content.res.Resources
import de.jasonstream.core.R as CoreR
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.core.security.Redactor
import de.jasonstream.player.R
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import javax.net.ssl.SSLException

/** Übersetzbare Fehlermeldung: String-Ressource (+ Argumente) oder Rohtext. */
data class ErrorText(val res: Int? = null, val args: List<Any> = emptyList(), val raw: String? = null) {
    fun resolve(r: Resources): String = when {
        res == null -> raw.orEmpty()
        args.isEmpty() -> r.getString(res)
        else -> r.getString(res, *args.toTypedArray())
    }
}

/**
 * Fehler → verständlicher Text in der App-Sprache (Port von
 * Redactor.friendly). Die Repositories werfen deutsche Texte; bekannte
 * werden auf übersetzte Strings abgebildet, alles andere bleibt (ohne
 * Zugangsdaten) im Original.
 */
object FriendlyError {
    /** Deutsche Meldungen aus :data → String-Ressource. */
    private val known: List<Pair<String, Int>> = listOf(
        "Zu viele Weiterleitungen" to CoreR.string.tooManyRedirects,
        "Antwort des Servers ist zu groß" to CoreR.string.serversResponseToo,
        "Weiterleitung auf unverschlüsselte" to CoreR.string.redirectUnencryptedConnection,
        "Ungültige Weiterleitung" to CoreR.string.invalidRedirectFrom,
        "Unsichere Adresse blockiert" to CoreR.string.unsafeAddressBlocked,
        "An deinem Standort nicht verfügbar" to CoreR.string.notAvailableLocationHttp,
        "Das Portal hat eine ungültige Antwort" to CoreR.string.serverSentInvalid,
        "Login fehlgeschlagen" to R.string.tv_errLoginFailed,
        "keine gültige M3U" to R.string.tv_errNoM3u,
        "Ungültige Portal-Adresse" to R.string.tv_errBadPortalUrl,
        "Ungültige Adresse" to CoreR.string.invalidAddress,
        "Ungültige MAC-Adresse" to CoreR.string.macAddressMust,
        "Portal lehnt die MAC-Adresse ab" to R.string.tv_errMacRejected,
        "Portal verweigert den Zugriff" to R.string.tv_errMacNotActivated,
        "Kein MAC-Portal" to R.string.tv_errNoMacPortal,
        "Kein Token" to R.string.tv_errNoMacPortal,
        "Leere Antwort" to CoreR.string.serverSentInvalid,
    )

    fun of(e: Throwable): ErrorText {
        // Ursache bis zur eigentlichen Netzwerk-Ausnahme verfolgen.
        var c: Throwable? = e
        var depth = 0
        while (c != null && depth < 6) {
            when (c) {
                is SocketTimeoutException -> return ErrorText(CoreR.string.serverIsntResponding)
                is SSLException, is CertificateException -> return ErrorText(CoreR.string.secureConnectionFailed)
                is UnknownHostException, is ConnectException, is NoRouteToHostException, is SocketException ->
                    return ErrorText(CoreR.string.serverUnreachableCheck)
                is InterruptedIOException -> if (c.message?.contains("timeout", true) == true) return ErrorText(CoreR.string.serverIsntResponding)
                is RepositoryException -> return repo(c)
            }
            c = c.cause.takeIf { it !== c }
            depth++
        }
        if (e.javaClass.name.contains("Serialization") || e is NumberFormatException || e is IllegalStateException && e.message?.contains("JSON", true) == true) {
            return ErrorText(CoreR.string.serverSentInvalid)
        }
        return ErrorText(raw = Redactor.redact(e.message ?: e.javaClass.simpleName))
    }

    private fun repo(e: RepositoryException): ErrorText {
        val msg = e.message.orEmpty()
        when (val code = e.statusCode) {
            401, 403 -> return ErrorText(CoreR.string.accessDeniedHttp, listOf("$code"))
            451 -> return ErrorText(CoreR.string.notAvailableLocationHttp)
            null -> Unit
            else -> if (msg.startsWith("Server antwortet mit HTTP")) return ErrorText(CoreR.string.serverHttpError, listOf("$code"))
        }
        known.firstOrNull { msg.contains(it.first) }?.let { return ErrorText(it.second) }
        return ErrorText(raw = Redactor.redact(msg))
    }
}
