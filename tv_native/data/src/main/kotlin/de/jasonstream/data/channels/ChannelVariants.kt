package de.jasonstream.data.channels

import de.jasonstream.core.model.Channel

/**
 * Sender-Varianten („ZDF HD“, „ZDF FHD“, „DE: ZDF ᴴᴰ“, „ZDF (Backup)“ …)
 * zu Gruppen zusammenfassen und nach Qualität sortieren – Port von
 * lib/data/channel_variants.dart (gleiche Regeln, gleiche Testfälle):
 * gleicher normalisierter Name UND (gleiche Gruppe ODER gleiches Land),
 * nie bei verschiedenen Ländern, nie bei Namen < 2 Zeichen.
 */
enum class VariantQuality { fhd, hd, unknown, uhd, raw, sd }

data class VariantName(val key: String, val country: String?, val quality: VariantQuality, val backup: Boolean) {
    /** Kleiner = besser. FHD, HD, ohne Angabe, 4K, RAW, SD – Backups zuletzt. */
    val rank: Int get() = quality.ordinal + (if (backup) 10 else 0)

    val label: String
        get() {
            val q = when (quality) {
                VariantQuality.fhd -> "FHD"
                VariantQuality.hd -> "HD"
                VariantQuality.uhd -> "4K"
                VariantQuality.raw -> "RAW"
                VariantQuality.sd -> "SD"
                VariantQuality.unknown -> ""
            }
            if (backup) return if (q.isEmpty()) "Backup" else "$q · Backup"
            return q
        }
}

private val superscript = mapOf(
    'ᴬ' to "A", 'ᴮ' to "B", 'ᴰ' to "D", 'ᴱ' to "E", 'ᴳ' to "G", 'ᴴ' to "H", 'ᴵ' to "I",
    'ᴶ' to "J", 'ᴷ' to "K", 'ᴸ' to "L", 'ᴹ' to "M", 'ᴺ' to "N", 'ᴼ' to "O", 'ᴾ' to "P",
    'ᴿ' to "R", 'ᵀ' to "T", 'ᵁ' to "U", 'ⱽ' to "V", 'ᵂ' to "W", 'ᵃ' to "a", 'ᵇ' to "b",
    'ᶜ' to "c", 'ᵈ' to "d", 'ᵉ' to "e", 'ᶠ' to "f", 'ᵍ' to "g", 'ʰ' to "h", 'ⁱ' to "i",
    'ʲ' to "j", 'ᵏ' to "k", 'ˡ' to "l", 'ᵐ' to "m", 'ⁿ' to "n", 'ᵒ' to "o", 'ᵖ' to "p",
    'ʳ' to "r", 'ˢ' to "s", 'ᵗ' to "t", 'ᵘ' to "u", 'ᵛ' to "v", 'ʷ' to "w", 'ˣ' to "x",
    'ʸ' to "y", 'ᶻ' to "z", '⁰' to "0", '¹' to "1", '²' to "2", '³' to "3", '⁴' to "4",
    '⁵' to "5", '⁶' to "6", '⁷' to "7", '⁸' to "8", '⁹' to "9", 'ᶦ' to "i",
)

private val prefixRe = Regex(
    "^\\s*(?:[|\\[(]\\s*([A-Za-z]{2,4})\\s*[|\\])]|([A-Z]{2,4}|[a-z]{2})\\s*(?:[:|▎┃•»]|\\s-\\s|-\\s))\\s*",
)

private val extraCountries = setOf(
    "EN", "IE", "AU", "NZ", "BR", "MT", "LT", "LV", "EE", "IS", "IL", "JP", "KR", "CN", "AZ", "GE", "AM",
    "KZ", "CY", "LU", "SA", "AE", "EG", "MA", "DZ", "TN", "IQ", "SY", "LB", "JO", "QA", "KW", "ZA", "NG",
    "PH", "TH", "VN", "ID", "MY", "BD", "LK", "NP", "CL", "CO", "PE", "VE", "EC", "UY", "PY", "BO", "CR",
    "PA", "DO", "CU", "PR", "HK", "TW", "SG", "AFR", "ASIA",
)

private val nonWord = Regex("[^\\p{L}\\p{N}+]+")
private val uhdSet = setOf("4k", "8k", "uhd", "2160p", "2160", "uhd4k")
private val fhdSet = setOf("fhd", "1080p", "1080i", "1080", "fullhd")
private val hdSet = setOf("hd", "720p", "720", "hq", "hdr")
private val sdSet = setOf("sd", "576p", "576i", "576", "480p", "480", "lq", "low")
private val rawSet = setOf("raw")
private val codecSet = setOf("hevc", "h265", "h264", "x265", "x264", "avc", "50fps", "60fps", "25fps", "30fps", "fps")
private val backupSet = setOf("backup", "bkp", "bk", "alt", "yedek", "reserve", "ersatz")
private val backupGlued = Regex("^(?:backup|alt|bkp|yedek)\\d+$")
private val hashRe = Regex("^#\\d+$")
private val hashNum = Regex("#(\\d+)")

/** Wörter (Buchstaben, Ziffern, „+“); ASCII ohne RegExp. */
private fun words(s: String): List<String> {
    val out = ArrayList<String>()
    var start = -1
    for (i in s.indices) {
        val u = s[i].code
        if (u >= 0x80) return s.split(nonWord).filter { it.isNotEmpty() }
        val word = (u in 0x61..0x7A) || (u in 0x30..0x39) || (u in 0x41..0x5A) || u == 0x2B
        if (word) {
            if (start < 0) start = i
        } else if (start >= 0) {
            out.add(s.substring(start, i)); start = -1
        }
    }
    if (start >= 0) out.add(s.substring(start))
    return out
}

private fun hasSuperscript(s: String) = s.any { it.code >= 0xB2 && superscript.containsKey(it) }
private fun isDigit(c: Char) = c in '0'..'9'
private fun allDigits(t: String) = t.isNotEmpty() && t.all { isDigit(it) }

/** Zerlegt [name] in normalisierten Namen, Land, Qualität und Backup-Flag. */
fun analyzeVariantName(name: String): VariantName {
    var s = name
    if (hasSuperscript(s)) {
        val b = StringBuilder()
        var inSup = false
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val ch = String(Character.toChars(cp))
            val m = if (cp <= 0xFFFF) superscript[cp.toChar()] else null
            if (m != null) {
                if (!inSup) b.append(' ')
                b.append(m)
                inSup = true
            } else {
                if (inSup) b.append(' ')
                b.append(ch)
                inSup = false
            }
            i += Character.charCount(cp)
        }
        s = b.toString()
    }

    var country: String? = null
    val pm = prefixRe.find(s)
    if (pm != null && pm.range.last + 1 < s.length) {
        val tok = (pm.groups[1]?.value ?: pm.groups[2]!!.value).uppercase()
        val code = CountryDetector.normalizeCode(tok) ?: (if (tok in extraCountries) tok else null)
        if (code != null) {
            country = code
            s = s.substring(pm.range.last + 1)
        }
    }

    if (s.contains('İ') || s.contains('ı')) s = s.replace('İ', 'i').replace('ı', 'i')
    s = s.lowercase()
    if (s.contains('#')) s = hashNum.replace(s) { " bkpnr${it.groupValues[1]} " }
    val raw = words(s)

    var quality = VariantQuality.unknown
    var backup = false
    fun q(v: VariantQuality) {
        if (quality == VariantQuality.unknown) quality = v
    }

    val kept = ArrayList<String>()
    var i = 0
    while (i < raw.size) {
        val t = raw[i]
        val prev = if (i > 0) raw[i - 1] else null
        val next = if (i + 1 < raw.size) raw[i + 1] else null
        if (t == "full" && next == "hd") {
            q(VariantQuality.fhd)
            i += 2
            continue
        }
        when {
            t in uhdSet -> q(VariantQuality.uhd)
            t in fhdSet -> q(VariantQuality.fhd)
            t in hdSet -> q(VariantQuality.hd)
            t in sdSet -> q(VariantQuality.sd)
            t in rawSet -> q(VariantQuality.raw)
            t == "50" || t == "60" -> if (!isFpsContext(raw, i)) kept.add(t)
            t in codecSet -> Unit
            t in backupSet ||
                (isDigit(t.last()) && (backupGlued.matches(t) || t.startsWith("bkpnr"))) ||
                (t.startsWith("#") && hashRe.matches(t)) -> backup = true
            allDigits(t) && prev != null && prev in backupSet -> backup = true
            else -> kept.add(t)
        }
        i++
    }
    return VariantName(kept.joinToString(" "), country, quality, backup)
}

private fun isFpsContext(raw: List<String>, i: Int): Boolean {
    val next = raw.getOrNull(i + 1)
    val prev = raw.getOrNull(i - 1)
    if (next == "fps") return true
    return prev != null && (prev in uhdSet || prev in fhdSet || prev in hdSet || prev in sdSet)
}

/** Gruppe von Varianten desselben Senders (beste zuerst). */
class VariantGroup(val key: String, val members: List<Channel>, val names: Map<String, VariantName>) {
    val best: Channel get() = members.first()
    val size: Int get() = members.size

    fun labelOf(c: Channel): String = names[c.id]?.label?.ifEmpty { null } ?: c.name

    /** Gewählte Variante zuerst, dann nach Rang. */
    fun playOrder(chosenId: String?): List<Channel> {
        if (chosenId == null) return members
        val i = members.indexOfFirst { it.id == chosenId }
        if (i <= 0) return members
        return listOf(members[i]) + members.filter { it.id != chosenId }
    }
}

/** Ergebnis der Gruppierung ohne Sender-Objekte. */
data class VariantCluster(val key: String, val idx: List<Int>, val names: List<VariantName>)

private class Cluster(val name: String) {
    var country: String? = null
    val groups = HashSet<String>()
    val idx = ArrayList<Int>()
}

/** Ab so vielen Sendern im Hintergrund rechnen. */
const val VARIANT_BACKGROUND_THRESHOLD = 4000

/** Reine Gruppierung über (Namen, Gruppen-IDs). */
fun clusterVariantNames(labels: List<String>, cats: List<String>): List<VariantCluster> {
    val names = labels.map { analyzeVariantName(it) }
    val byName = LinkedHashMap<String, MutableList<Cluster>>()
    for (i in names.indices) {
        val n = names[i]
        if (n.key.replace(" ", "").length < 2) continue
        val cat = cats[i]
        val list = byName.getOrPut(n.key) { ArrayList() }
        var hit: Cluster? = null
        for (cl in list) {
            if (cl.country != null && n.country != null && cl.country != n.country) continue
            val sameGroup = cat in cl.groups
            val sameCountry = n.country != null && cl.country == n.country
            if (sameGroup || sameCountry) { hit = cl; break }
        }
        if (hit == null) {
            hit = Cluster(n.key)
            list.add(hit)
        }
        if (hit.country == null) hit.country = n.country
        hit.groups.add(cat)
        hit.idx.add(i)
    }
    val out = ArrayList<VariantCluster>()
    for (list in byName.values) {
        for (cl in list) {
            if (cl.idx.size < 2) continue
            val sorted = cl.idx.sortedWith { a, b ->
                val r = names[a].rank.compareTo(names[b].rank)
                if (r != 0) r else a.compareTo(b)
            }
            out.add(VariantCluster("${cl.name}|${cl.country ?: "g:${cats[cl.idx.first()]}"}", sorted, sorted.map { names[it] }))
        }
    }
    return out
}

fun groupVariants(channels: List<Channel>): List<VariantGroup> =
    clusterVariantNames(channels.map { it.name }, channels.map { it.categoryId }).map { cl ->
        VariantGroup(cl.key, cl.idx.map { channels[it] }, cl.idx.indices.associate { k -> channels[cl.idx[k]].id to cl.names[k] })
    }

/** Nachschlagetabelle über alle Gruppen. */
class VariantIndex private constructor(
    private val byMember: Map<String, VariantGroup>,
    private val rep: Map<String, String>,
) {
    companion object {
        val empty = VariantIndex(emptyMap(), emptyMap())

        /**
         * Vertreter: 1. nur nicht ausgeblendete, 2. gesperrte zuerst
         * (Kindersicherung nicht umgehbar), 3. Favorit, 4. beste Variante.
         */
        fun of(
            groups: List<VariantGroup>,
            favorites: Set<String> = emptySet(),
            hidden: Set<String> = emptySet(),
            locked: Set<String> = emptySet(),
        ): VariantIndex {
            val by = HashMap<String, VariantGroup>()
            val rep = HashMap<String, String>()
            for (g in groups) {
                for (c in g.members) by[c.id] = g
                var cands = g.members.filter { it.id !in hidden }
                if (cands.isEmpty()) cands = g.members
                if (locked.isNotEmpty()) {
                    val lk = cands.filter { it.id in locked }
                    if (lk.isNotEmpty()) cands = lk
                }
                rep[g.key] = (cands.firstOrNull { it.id in favorites } ?: cands.first()).id
            }
            return VariantIndex(by, rep)
        }
    }

    val isEmpty: Boolean get() = byMember.isEmpty()

    fun resolve(ids: Iterable<String>, byId: Map<String, Channel>): List<Channel> {
        val seen = HashSet<String>()
        val out = ArrayList<Channel>()
        for (id in ids) {
            val c = byId[id] ?: byId[representativeOf(id)]
            if (c != null && seen.add(c.id)) out.add(c)
        }
        return out
    }

    fun groupOf(channelId: String) = byMember[channelId]
    fun countOf(channelId: String) = byMember[channelId]?.size ?: 1
    fun representativeOf(channelId: String): String {
        val g = byMember[channelId] ?: return channelId
        return rep[g.key] ?: channelId
    }
    fun isRepresentative(channelId: String) = representativeOf(channelId) == channelId

    /** Liste ohne verdeckte Varianten; fehlende Logos/EPG-Kennungen von anderen Varianten. */
    fun collapse(channels: List<Channel>): List<Channel> {
        if (byMember.isEmpty()) return channels
        val out = ArrayList<Channel>()
        for (c in channels) {
            val g = byMember[c.id]
            if (g == null) { out.add(c); continue }
            if (rep[g.key] != c.id) continue
            fun pick(f: (Channel) -> String?): String? {
                if (!f(c).isNullOrEmpty()) return null
                return g.members.firstNotNullOfOrNull { m -> f(m)?.takeIf { it.isNotEmpty() } }
            }
            val logo = pick { it.logoUrl }
            val epg = pick { it.epgId }
            out.add(if (logo == null && epg == null) c else c.copy(logoUrl = logo ?: c.logoUrl, epgId = epg ?: c.epgId))
        }
        return out
    }
}
