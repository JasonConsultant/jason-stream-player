package de.jasonstream.data.m3u

import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.data.net.StreamHeaders
import okio.BufferedSource
import kotlin.math.floor

/**
 * M3U/M3U8-Parser – Port von m3u_parser.dart, aber **zeilenweise** (auch
 * direkt aus dem Netz-Datenstrom, ohne die ganze Datei als Text zu halten).
 *
 * #EXTINF-Attribute: tvg-id, tvg-name, tvg-logo, tvg-chno, group-title,
 * catchup, catchup-days, catchup-source, timeshift, tvg-shift;
 * Header: #EXTVLCOPT, #KODIPROP …_headers, #EXTHTTP, „|User-Agent=…“.
 */
class M3uParser {
    data class Result(val channels: List<Channel>, val categories: List<Category>, val epgUrl: String?)

    companion object {
        private val attrRe = Regex("([a-zA-Z0-9\\-_]+)=\"([^\"]*)\"")

        fun parse(content: String): Result {
            val p = M3uParser()
            content.split(Regex("\\r?\\n")).forEach { p.line(it) }
            return p.finish()
        }

        /** Streaming: Zeile für Zeile aus [source] (UTF-8). Liefert null, wenn kein #EXTINF vorkommt. */
        fun parse(source: BufferedSource): Result? {
            val p = M3uParser()
            while (true) {
                val l = source.readUtf8Line() ?: break
                p.line(l)
            }
            return if (p.sawExtinf) p.finish() else null
        }

        private fun attrs(line: String): Map<String, String> =
            attrRe.findAll(line).associate { it.groupValues[1] to it.groupValues[2] }

        /** Das Komma vor dem Sendernamen – nicht eines innerhalb von "…". */
        internal fun nameComma(line: String): Int {
            var inQuotes = false
            for (i in line.indices) {
                val ch = line[i]
                if (ch == '"') inQuotes = !inQuotes
                if (ch == ',' && !inQuotes) return i
            }
            return -1
        }

        private fun nz(s: String?) = if (s.isNullOrEmpty()) null else s

        /** Dart int.tryParse (Leerzeichen erlaubt). */
        private fun dInt(s: String?): Int? = s?.trim()?.toIntOrNull()

        /** tvg-shift in Stunden („-1.5“, „+2“) → Minuten (±12 h). */
        internal fun shiftMinutes(v: String?): Int {
            val h = (v ?: "").trim().replace(',', '.').replace("+", "").toDoubleOrNull() ?: return 0
            if (h.isNaN() || h.isInfinite()) return 0
            val m = h * 60
            val r = if (m < 0) -floor(-m + 0.5) else floor(m + 0.5) // Dart round(): weg von 0
            return r.toInt().coerceIn(-720, 720)
        }

        private fun trimDart(s: String) = s.trim().trim('﻿').trim()
    }

    private val channels = ArrayList<Channel>()
    private val groups = LinkedHashMap<String, Category>()
    private var epgUrl: String? = null
    private var header: Map<String, String> = emptyMap()
    private var pendingName: String? = null
    private var attrs: Map<String, String> = emptyMap()
    private var extGrp: String? = null
    private var optHeaders = LinkedHashMap<String, String>()
    private var number = 0
    var sawExtinf = false
        private set

    fun line(raw: String) {
        val line = trimDart(raw)
        if (line.isEmpty()) return
        if (line.startsWith("#EXTM3U")) {
            header = attrs(line)
            val urls = (header["x-tvg-url"] ?: header["url-tvg"] ?: "")
                .split(',').map { it.trim() }.filter { UrlPolicy.isWeb(it) }
            epgUrl = if (urls.isEmpty()) null else urls.joinToString(",")
            return
        }
        if (line.startsWith("#EXTINF")) {
            sawExtinf = true
            attrs = attrs(line)
            val comma = nameComma(line)
            pendingName = if (comma >= 0) line.substring(comma + 1).trim() else "Sender"
            return
        }
        if (line.startsWith("#EXTGRP:")) {
            extGrp = line.substring(8).trim()
            return
        }
        if (line.startsWith("#EXTVLCOPT") || line.startsWith("#KODIPROP") || line.startsWith("#EXTHTTP")) {
            optHeaders.putAll(StreamHeaders.parseM3uOptionLine(line))
            return
        }
        if (line.startsWith("#")) return

        val (url, pipeHeaders) = StreamHeaders.splitPipeHeaders(line)
        val headers = LinkedHashMap(optHeaders).apply { putAll(pipeHeaders) }
        optHeaders = LinkedHashMap()

        val name = pendingName
        if (name != null && !UrlPolicy.isStream(url)) {
            pendingName = null; attrs = emptyMap(); extGrp = null
            return
        }
        if (name != null) {
            val groupName = attrs["group-title"] ?: extGrp ?: "Allgemein"
            val cat = groups.getOrPut(groupName) { Category(groupName, groupName) }
            number++
            val days = dInt(attrs["catchup-days"] ?: attrs["timeshift"] ?: header["catchup-days"] ?: "") ?: 0
            channels.add(
                Channel(
                    id = "m3u_$number",
                    name = name,
                    logoUrl = UrlPolicy.image(nz(attrs["tvg-logo"])),
                    categoryId = cat.id,
                    streamUrl = url,
                    epgId = nz(attrs["tvg-id"]) ?: nz(attrs["tvg-name"]),
                    number = dInt(attrs["tvg-chno"]) ?: number,
                    catchupDays = days,
                    catchupMode = attrs["catchup"] ?: header["catchup"],
                    catchupSource = attrs["catchup-source"] ?: header["catchup-source"],
                    headers = headers.ifEmpty { null },
                    epgShift = shiftMinutes(attrs["tvg-shift"] ?: header["tvg-shift"]),
                ),
            )
            pendingName = null; attrs = emptyMap(); extGrp = null
        }
    }

    fun finish() = Result(channels, groups.values.toList(), epgUrl)
}
