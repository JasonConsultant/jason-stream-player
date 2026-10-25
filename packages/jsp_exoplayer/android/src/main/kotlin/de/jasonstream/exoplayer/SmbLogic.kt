package de.jasonstream.exoplayer

/**
 * Reine Logik für das Netzlaufwerk (SMB 2/3): Ziel prüfen/normalisieren,
 * Pfade zusammensetzen, Fehler einordnen, Range-Anfragen des lokalen
 * Wiedergabe-Proxys lesen. Ohne Android/SMB-Abhängigkeit → JVM-Tests.
 */
data class SmbTarget(
    val host: String,
    val port: Int,
    val share: String,
    /** Basisordner in der Freigabe, mit „\“ getrennt, ohne führenden/abschließenden Trenner. */
    val base: String,
    val user: String,
    val password: String,
    val domain: String,
) {
    /** Schlüssel für die Verbindungs-Wiederverwendung (ohne Passwort im Klartext). */
    val key: String get() = "$host:$port/$share|$user@$domain|${password.hashCode()}"

    /** Relativen Pfad (mit „/“ oder „\“) unter dem Basisordner. */
    fun path(rel: String): String = SmbLogic.join(base, rel)

    companion object {
        /** Aus den Kanal-Argumenten; null = ungültig. */
        fun from(m: Map<*, *>?): SmbTarget? {
            if (m == null) return null
            val server = (m["server"] as? String)?.trim().orEmpty()
            val share = SmbLogic.cleanShare((m["share"] as? String).orEmpty())
            if (server.isEmpty() || share.isEmpty()) return null
            val (host, port) = SmbLogic.hostPort(server) ?: return null
            val base = SmbLogic.cleanPath((m["path"] as? String).orEmpty()) ?: return null
            return SmbTarget(
                host = host,
                port = port,
                share = share,
                base = base,
                user = (m["user"] as? String)?.trim().orEmpty(),
                password = (m["password"] as? String).orEmpty(),
                domain = (m["domain"] as? String)?.trim().orEmpty(),
            )
        }
    }
}

object SmbLogic {
    /** „nas“, „nas:4455“, „smb://nas/“, „\\nas“, „[fe80::1]:445“ → (Host, Port). */
    fun hostPort(raw: String): Pair<String, Int>? {
        var s = raw.trim()
        s = s.removePrefix("smb://").removePrefix("SMB://").trimStart('\\', '/')
        s = s.substringBefore('/').substringBefore('\\')
        if (s.isEmpty()) return null
        var port = 445
        var host = s
        if (s.startsWith("[")) {
            val end = s.indexOf(']')
            if (end < 0) return null
            host = s.substring(1, end)
            val rest = s.substring(end + 1)
            if (rest.startsWith(":")) port = rest.substring(1).toIntOrNull() ?: return null
        } else if (s.count { it == ':' } == 1) {
            host = s.substringBefore(':')
            port = s.substringAfter(':').toIntOrNull() ?: return null
        }
        if (host.isEmpty() || port !in 1..65535) return null
        if (host.any { it.isWhitespace() || it == '@' }) return null
        return host to port
    }

    fun cleanShare(raw: String): String =
        raw.trim().trim('\\', '/').substringBefore('/').substringBefore('\\')

    /** Pfad normalisieren; „..“ (Ausbruch aus dem Basisordner) → null. */
    fun cleanPath(raw: String): String? {
        val parts = raw.replace('/', '\\').split('\\').map { it.trim() }.filter { it.isNotEmpty() && it != "." }
        if (parts.any { it == ".." }) return null
        if (parts.any { p -> p.any { it in "<>:\"|?*" || it.code < 32 } }) return null
        return parts.joinToString("\\")
    }

    fun join(base: String, rel: String): String {
        val r = cleanPath(rel) ?: throw IllegalArgumentException("bad path")
        return when {
            base.isEmpty() -> r
            r.isEmpty() -> base
            else -> "$base\\$r"
        }
    }

    /** Elternordner eines Pfads („a\b\c.mkv“ → „a\b“). */
    fun parent(path: String): String = path.substringBeforeLast('\\', "")

    /**
     * Fehler → Code für Dart: auth, host, share, path, denied, full, smb1,
     * timeout, io. [status] ist der NT-Status-Name (falls vorhanden).
     */
    fun classify(type: String, message: String?, status: String?): String {
        val m = (message ?: "").lowercase()
        val s = (status ?: "").uppercase()
        return when {
            s.contains("LOGON_FAILURE") || s.contains("ACCOUNT_") || s.contains("WRONG_PASSWORD") ||
                s.contains("PASSWORD_EXPIRED") -> "auth"
            s.contains("BAD_NETWORK_NAME") || s.contains("BAD_NETWORK_PATH") -> "share"
            s.contains("OBJECT_PATH_NOT_FOUND") || s.contains("OBJECT_NAME_NOT_FOUND") ||
                s.contains("NOT_A_DIRECTORY") -> "path"
            s.contains("ACCESS_DENIED") || s.contains("SHARING_VIOLATION") -> "denied"
            s.contains("DISK_FULL") || s.contains("QUOTA") -> "full"
            m.contains("smb1") || m.contains("smbv1") ||
                (m.contains("dialect") && (m.contains("not supported") || m.contains("negotiat"))) -> "smb1"
            type.contains("UnknownHost") -> "host"
            type.contains("Timeout") || m.contains("timed out") || m.contains("timeout") -> "timeout"
            type.contains("ConnectException") || type.contains("NoRouteToHost") ||
                m.contains("connection refused") || m.contains("unreachable") -> "host"
            else -> "io"
        }
    }

    /** „bytes=100-“, „bytes=100-199“, „bytes=-500“ → (Start, Ende inkl.); null = ungültig/kein Range. */
    fun range(header: String?, size: Long): Pair<Long, Long>? {
        if (header == null || !header.startsWith("bytes=") || size <= 0) return null
        val spec = header.removePrefix("bytes=").substringBefore(',').trim()
        val a = spec.substringBefore('-').trim()
        val b = spec.substringAfter('-', "").trim()
        return when {
            a.isEmpty() && b.isNotEmpty() -> {
                val n = b.toLongOrNull() ?: return null
                if (n <= 0) null else maxOf(0, size - n) to size - 1
            }
            a.isNotEmpty() -> {
                val start = a.toLongOrNull() ?: return null
                val end = if (b.isEmpty()) size - 1 else (b.toLongOrNull() ?: return null)
                if (start >= size || end < start) null else start to minOf(end, size - 1)
            }
            else -> null
        }
    }

    fun mime(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "ts", "m2ts" -> "video/mp2t"
        "webm" -> "video/webm"
        "avi" -> "video/x-msvideo"
        "srt" -> "application/x-subrip"
        else -> "video/x-matroska"
    }
}
