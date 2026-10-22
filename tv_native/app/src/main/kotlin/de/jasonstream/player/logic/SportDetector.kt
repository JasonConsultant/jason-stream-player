package de.jasonstream.player.logic

/**
 * Erkennt Sport-Sendungen und Sport-Gruppen (Deutsch, Englisch, Türkisch)
 * anhand von Titel, EPG-Kategorie und Gruppenname – Port von
 * lib/data/sport_detect.dart. Wortbasiert, damit „Sportschau“ oder
 * „Motorsport“ zählen, „Transport“ aber nicht.
 */
object SportDetector {
    private val word = Regex("[\\p{L}\\p{N}]+")

    private val words = setOf(
        "fußball", "fussball", "football", "soccer", "futbol", "bundesliga",
        "tennis", "f1", "formel1", "formula1", "motogp", "nascar", "basketball",
        "basketbol", "voleybol", "volleyball", "handball", "hentbol", "ufc",
        "mma", "boxen", "boxing", "boks", "wrestling", "wwe", "nba", "nfl",
        "nhl", "mlb", "uefa", "fifa", "dfb", "eishockey", "hockey", "darts",
        "snooker", "biathlon", "skispringen", "leichtathletik", "athletics",
        "atletizm", "radsport", "cycling", "bisiklet", "rugby", "cricket",
        "golf", "superbowl", "maç", "mac", "derbi", "derby", "olympia",
        "olympics", "olimpiyat", "liga", "ligi", "pokal", "kupa", "grand",
        "esports", "esport", "pga", "atp", "wta", "euroleague",
    )

    private val pairs = setOf(
        "champions" to "league", "europa" to "league", "conference" to "league",
        "premier" to "league", "la" to "liga", "serie" to "a", "süper" to "lig",
        "super" to "lig", "formel" to "1", "formula" to "1", "tour" to "de",
        "grand" to "prix", "world" to "cup", "dünya" to "kupası",
        "ski" to "alpin", "ski" to "weltcup",
    )

    private val weak = setOf("liga", "ligi", "pokal", "kupa", "grand", "mac", "derby", "golf")
    private val notSport = listOf("transport", "passport", "disport", "sporad", "sporen", "spore")

    private val cache = HashMap<String, Boolean>()

    private fun sportToken(t: String): Boolean {
        if (t.contains("sport") || t.startsWith("spor")) {
            for (n in notSport) if (t.startsWith(n)) return false
            val i = t.indexOf("spor")
            if (i == 0) return true
            val at = t.indexOf("sport")
            return at > 0 && (t.endsWith("sport") || t.endsWith("sports"))
        }
        return false
    }

    /** Ist dieser Text (Titel, Kategorie) Sport? Ergebnis wird gemerkt. */
    fun isSportText(text: String?): Boolean {
        if (text.isNullOrEmpty()) return false
        synchronized(cache) { cache[text]?.let { return it } }
        val r = detect(text)
        synchronized(cache) {
            if (cache.size > 20000) cache.clear()
            cache[text] = r
        }
        return r
    }

    private fun detect(text: String): Boolean {
        val toks = word.findAll(text.lowercase()).map { it.value }.toList()
        for (i in toks.indices) {
            val t = toks[i]
            if (sportToken(t)) return true
            if (t in words && t !in weak) return true
            if (i + 1 < toks.size && (t to toks[i + 1]) in pairs) return true
        }
        return false
    }

    /** Gruppen wie „DE | Sport“, „TR: Spor“, „Sports HD“. */
    fun isSportGroup(name: String?): Boolean {
        if (name.isNullOrEmpty()) return false
        return word.findAll(name.lowercase()).any { sportToken(it.value) }
    }

    fun isSportProgramme(title: String, genre: String? = null, sportGroup: Boolean = false) =
        sportGroup || isSportText(genre) || isSportText(title)
}
