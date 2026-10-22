package de.jasonstream.data.channels

/**
 * Erwachsenen- und Ländererkennung in Gruppen-/Sendernamen
 * (Port von lib/data/content_filters.dart).
 */
private fun norm(s: String) = s.replace('İ', 'i').replace('I', 'i').replace('ı', 'i').lowercase()

object AdultDetector {
    private val words = Regex(
        "(?<![\\p{L}\\p{N}])(" +
            "x{3,}" +
            "|adult(?:s|os|as|es|e|i|o)?" +
            "|erwachsene\\p{L}*" +
            "|yeti[sş]kin\\p{L}*" +
            "|porn\\p{L}*" +
            "|hustler|playboy|brazzers|private|penthouse|dorcel|redlight" +
            ")(?![\\p{L}\\p{N}])",
    )
    private val eighteen = Regex("(?<![\\p{N}])(?:18\\s?\\+|\\+\\s?18)(?![\\p{N}])")
    private val harmless = Regex("adult\\s*swim")

    fun isAdult(name: String): Boolean {
        val n = norm(name)
        if (n.isEmpty()) return false
        if (eighteen.containsMatchIn(n)) return true
        val m = words.find(n) ?: return false
        if (harmless.containsMatchIn(n) && words.findAll(n).count() == 1 && m.groupValues[1].startsWith("adult")) {
            return false
        }
        return true
    }
}

object CountryDetector {
    /** Sammelbecken für alles ohne erkennbares Land. */
    const val NONE = "_none"

    val codes = listOf(
        "DE", "AT", "CH", "TR", "UK", "AL", "FR", "IT", "ES", "PT", "NL", "BE", "PL", "RO", "EXYU", "GR",
        "BG", "HU", "CZ", "RU", "UA", "SE", "NO", "DK", "FI", "KU", "AR", "IR", "IN", "PK", "AF", "US",
        "CA", "LATAM",
    )

    private val codeMap = mapOf(
        "DE" to "DE", "GER" to "DE", "DEU" to "DE", "AT" to "AT", "AUT" to "AT", "CH" to "CH", "SUI" to "CH",
        "TR" to "TR", "TUR" to "TR", "TRK" to "TR", "UK" to "UK", "GB" to "UK", "ENG" to "UK", "GBR" to "UK",
        "AL" to "AL", "ALB" to "AL", "FR" to "FR", "FRA" to "FR", "IT" to "IT", "ITA" to "IT", "ES" to "ES",
        "ESP" to "ES", "SPA" to "ES", "PT" to "PT", "POR" to "PT", "NL" to "NL", "NLD" to "NL", "NED" to "NL",
        "BE" to "BE", "BEL" to "BE", "PL" to "PL", "POL" to "PL", "RO" to "RO", "ROU" to "RO", "ROM" to "RO",
        "RS" to "EXYU", "SRB" to "EXYU", "EXYU" to "EXYU", "EX-YU" to "EXYU", "YU" to "EXYU", "HR" to "EXYU",
        "HRV" to "EXYU", "BA" to "EXYU", "BIH" to "EXYU", "MK" to "EXYU", "SI" to "EXYU", "SLO" to "EXYU",
        "ME" to "EXYU", "CG" to "EXYU", "GR" to "GR", "GRE" to "GR", "BG" to "BG", "BUL" to "BG", "HU" to "HU",
        "HUN" to "HU", "CZ" to "CZ", "CZE" to "CZ", "SK" to "CZ", "RU" to "RU", "RUS" to "RU", "UA" to "UA",
        "UKR" to "UA", "SE" to "SE", "SWE" to "SE", "NO" to "NO", "NOR" to "NO", "DK" to "DK", "DAN" to "DK",
        "FI" to "FI", "FIN" to "FI", "KU" to "KU", "KUR" to "KU", "AR" to "AR", "ARA" to "AR", "ARAB" to "AR",
        "IR" to "IR", "PER" to "IR", "IN" to "IN", "IND" to "IN", "PK" to "PK", "PAK" to "PK", "AF" to "AF",
        "AFG" to "AF", "US" to "US", "USA" to "US", "CA" to "CA", "CAN" to "CA", "LAT" to "LATAM",
        "LATAM" to "LATAM", "LATINO" to "LATAM", "MX" to "LATAM",
    )

    private val nameMap = mapOf(
        "germany" to "DE", "deutschland" to "DE", "german" to "DE", "deutsch" to "DE", "almanya" to "DE",
        "austria" to "AT", "österreich" to "AT", "osterreich" to "AT", "switzerland" to "CH", "schweiz" to "CH",
        "swiss" to "CH", "suisse" to "CH", "turkey" to "TR", "türkiye" to "TR", "turkiye" to "TR",
        "türkei" to "TR", "turkish" to "TR", "türk" to "TR", "turk" to "TR", "united kingdom" to "UK",
        "england" to "UK", "british" to "UK", "albania" to "AL", "albanien" to "AL", "shqip" to "AL",
        "shqiperia" to "AL", "france" to "FR", "french" to "FR", "frankreich" to "FR", "italy" to "IT",
        "italia" to "IT", "italien" to "IT", "italian" to "IT", "spain" to "ES", "españa" to "ES",
        "espana" to "ES", "spanien" to "ES", "portugal" to "PT", "netherlands" to "NL", "nederland" to "NL",
        "holland" to "NL", "dutch" to "NL", "niederlande" to "NL", "belgium" to "BE", "belgien" to "BE",
        "poland" to "PL", "polska" to "PL", "polen" to "PL", "romania" to "RO", "rumänien" to "RO",
        "serbia" to "EXYU", "srbija" to "EXYU", "ex-yu" to "EXYU", "exyu" to "EXYU", "balkan" to "EXYU",
        "yugoslavia" to "EXYU", "croatia" to "EXYU", "bosnia" to "EXYU", "hrvatska" to "EXYU",
        "greece" to "GR", "griechenland" to "GR", "bulgaria" to "BG", "hungary" to "HU", "czech" to "CZ",
        "russia" to "RU", "russland" to "RU", "ukraine" to "UA", "sweden" to "SE", "norway" to "NO",
        "denmark" to "DK", "finland" to "FI", "kurdish" to "KU", "kurdistan" to "KU", "kurdî" to "KU",
        "arabic" to "AR", "arab" to "AR", "arabisch" to "AR", "iran" to "IR", "persian" to "IR",
        "india" to "IN", "indian" to "IN", "pakistan" to "PK", "afghanistan" to "AF", "usa" to "US",
        "united states" to "US", "canada" to "CA", "latino" to "LATAM", "latin" to "LATAM", "mexico" to "LATAM",
    )

    private val prefix = Regex(
        "^[\\s|\\[(#*•\\-~★]*([A-Za-z]{2,6}(?:-[A-Za-z]{2})?)($|[\\s:|\\])•\\-_./,]|[^\\x00-\\x7F])",
    )

    /** Kürzel, die auch normale Wörter sein können: nur mit klarem Trenner. */
    private val ambiguous = setOf(
        "IN", "ME", "IT", "NO", "US", "CA", "SI", "BA", "AF", "ES", "SE", "BE", "CG", "MX", "AR", "PER",
        "CAN", "LAT", "SPA", "DAN", "FIN", "POR", "ARAB", "HR", "AL", "SK", "RS",
    )
    private val segments = Regex("[|:\\[\\]•()]")
    private val nameRe = Regex(
        "(?<![\\p{L}\\p{N}])(" +
            nameMap.keys.sortedByDescending { it.length }.joinToString("|") { Regex.escape(it) } +
            ")(?![\\p{L}\\p{N}])",
    )

    /** Bekanntes Länderkürzel („GER“ → „DE“), sonst null. */
    fun normalizeCode(token: String): String? = codeMap[token.uppercase()]

    /** Kürzel am Anfang oder als eigener Abschnitt. Nur Großschreibung zählt. */
    fun fromPrefix(name: String): String? {
        val m = prefix.find(name)
        if (m != null) {
            val tok = m.groupValues[1]
            val sep = m.groupValues[2]
            val rest = name.substring(m.range.last + 1 - sep.length).trimStart()
            val strongAfterSpace = sep.isBlank() && rest.isNotEmpty() && ":|]-)•".contains(rest[0])
            val weak = (sep.isBlank() && !strongAfterSpace) || sep == "." || sep == "_"
            if (tok == tok.uppercase() && !(weak && tok in ambiguous)) {
                codeMap[tok]?.let { return it }
            }
        }
        if (segments.containsMatchIn(name)) {
            for (part in name.split(segments)) {
                val t = part.trim()
                if (t.length < 2 || t.length > 6 || t != t.uppercase()) continue
                codeMap[t]?.let { return it }
            }
        }
        return null
    }

    /** Land einer Gruppe: Kürzel oder ausgeschriebener Ländername. */
    fun fromGroup(name: String): String? {
        fromPrefix(name)?.let { return it }
        val m = nameRe.find(name.lowercase()) ?: return null
        return nameMap[m.groupValues[1]]
    }

    fun forItem(name: String, groupCode: String?): String? = fromPrefix(name) ?: groupCode

    fun passes(code: String?, allowed: Set<String>) = allowed.isEmpty() || (code ?: NONE) in allowed
}
