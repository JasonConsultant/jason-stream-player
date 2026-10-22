package de.jasonstream.player.logic

import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.security.SimpleUri
import de.jasonstream.core.security.UrlPolicy
import java.util.UUID

/** Felder des Formulars „Portal hinzufügen / bearbeiten“. */
enum class PortalField { Name, Url, User, Pass, Mac, Epg }

/** Prüffehler je Feld (Text kommt aus den ARB-Strings, siehe PortalEditScreen). */
enum class FieldError { NameMissing, UrlMissing, UrlInvalid, Required, MacFormat, EpgInvalid }

/**
 * Eingaben des Formulars (Port von add_portal_screen.dart): Prüfung,
 * Normalisierung und Bau des [Portal]. Rein (ohne Android) – testbar.
 */
data class PortalForm(
    val type: PortalType = PortalType.xtream,
    val name: String = "",
    val url: String = "",
    val user: String = "",
    val pass: String = "",
    val mac: String = MAC_PREFIX,
    val epg: String = "",
) {
    /** Sichtbare Felder je Zugangsart. */
    val fields: List<PortalField>
        get() = when (type) {
            PortalType.xtream -> listOf(PortalField.Name, PortalField.Url, PortalField.User, PortalField.Pass, PortalField.Epg)
            PortalType.stalker -> listOf(PortalField.Name, PortalField.Url, PortalField.Mac, PortalField.Epg)
            else -> listOf(PortalField.Name, PortalField.Url, PortalField.Epg)
        }

    /** Adresse wie gespeichert: ohne Leerzeichen, fehlendes Schema → http://. */
    val normalizedUrl: String get() = normalizeUrl(url)
    val normalizedMac: String get() = normalizeMac(mac)

    /** http:// (Hinweis „Unverschlüsselte Verbindung“). */
    val unencrypted: Boolean get() = url.isNotBlank() && UrlPolicy.isUnencrypted(normalizedUrl)

    fun validate(): Map<PortalField, FieldError> {
        val e = LinkedHashMap<PortalField, FieldError>()
        // Name ist optional: leer → Rechnername der Adresse (Tippen mit der Fernbedienung sparen).
        if (url.isBlank()) e[PortalField.Url] = FieldError.UrlMissing
        else if (!UrlPolicy.isWeb(normalizedUrl)) e[PortalField.Url] = FieldError.UrlInvalid
        when (type) {
            PortalType.xtream -> {
                if (user.trim().isEmpty()) e[PortalField.User] = FieldError.Required
                if (pass.isEmpty()) e[PortalField.Pass] = FieldError.Required
            }
            PortalType.stalker -> if (!MAC_RE.matches(normalizedMac)) e[PortalField.Mac] = FieldError.MacFormat
            else -> Unit
        }
        val epgT = epg.trim()
        if (epgT.isNotEmpty() && !UrlPolicy.isWeb(normalizeUrl(epgT))) e[PortalField.Epg] = FieldError.EpgInvalid
        return e
    }

    /** Fertiges Portal (neu: neue ID; bearbeiten: ID + erweiterte Felder bleiben). */
    fun toPortal(edit: Portal? = null, newId: () -> String = { UUID.randomUUID().toString() }): Portal {
        val u = normalizedUrl
        val oldEpg = edit?.epgUrl.orEmpty()
        // Mehrere EPG-Quellen (zeilenweise) bleiben erhalten, solange das Feld leer ist.
        val keepSources = oldEpg.contains('\n') && epg.isBlank()
        val epgOut = if (keepSources) oldEpg else epg.trim().takeIf { it.isNotEmpty() }?.let { normalizeUrl(it) }
        val base = Portal(
            id = edit?.id ?: newId(),
            name = name.trim().ifEmpty { SimpleUri.parse(u)?.host?.takeIf { it.isNotEmpty() } ?: u },
            type = type,
            url = u,
            // MAC-Portal: MAC-Adresse steht (verschlüsselt) im Benutzernamen.
            username = when (type) {
                PortalType.xtream -> user.trim()
                PortalType.stalker -> normalizedMac
                else -> null
            },
            password = if (type == PortalType.xtream) pass else null,
            epgUrl = epgOut,
        )
        // Erweiterte Einstellungen (User-Agent, Referer, Ersatz-Adressen …) beibehalten.
        return if (edit == null) base else base.copy(
            userAgent = edit.userAgent,
            referer = edit.referer,
            altUrls = edit.altUrls,
            autoRefreshHours = edit.autoRefreshHours,
            epgOffsets = edit.epgOffsets,
        )
    }

    companion object {
        const val MAC_PREFIX = "00:1A:79:"
        val MAC_RE = Regex("^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")

        fun from(p: Portal): PortalForm = PortalForm(
            type = p.type,
            name = p.name,
            url = p.url,
            user = if (p.type == PortalType.stalker) "" else p.username.orEmpty(),
            pass = p.password.orEmpty(),
            mac = if (p.type == PortalType.stalker) p.username.orEmpty() else MAC_PREFIX,
            // Mehrere Quellen werden (später) unter „EPG-Quellen“ verwaltet.
            epg = p.epgUrl.orEmpty().takeIf { !it.contains('\n') && it != "portal" }.orEmpty(),
        )

        fun normalizeUrl(raw: String): String {
            val s = raw.trim().replace(" ", "")
            if (s.isEmpty()) return s
            return if (Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://").containsMatchIn(s)) s else "http://$s"
        }

        /** „00-1a-79-…“ / „001A79…“ → „00:1A:79:…“. */
        fun normalizeMac(raw: String): String {
            val s = raw.trim().uppercase().replace('-', ':')
            val hex = s.filter { it.isDigit() || it in 'A'..'F' }
            return if (!s.contains(':') && hex.length == 12 && hex.length == s.length) hex.chunked(2).joinToString(":") else s
        }
    }
}
