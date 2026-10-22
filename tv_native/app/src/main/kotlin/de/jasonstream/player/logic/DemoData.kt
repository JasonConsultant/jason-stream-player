package de.jasonstream.player.logic

import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import java.util.Calendar
import java.util.Random

/**
 * Demo-Quelle mit erfundenen Sendern und Programmen – Port von
 * lib/data/demo_repository.dart (alle Namen frei erfunden). Für das
 * Demo-Portal, Tests und Bildschirmfotos.
 */
object DemoData {
    const val TEST_STREAM = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    val categories = listOf(
        Category("de", "Deutschland"),
        Category("sport", "Sport"),
        Category("film", "Filme & Serien"),
        Category("doku", "Dokumentation"),
        Category("news", "Nachrichten"),
        Category("kids", "Kinder"),
        Category("music", "Musik"),
    )

    private val defs = listOf(
        Triple("Nordlicht 1 HD", "de", 7), Triple("Kanal Mitte HD", "de", 7), Triple("Rheinwelle FHD", "de", 7),
        Triple("Alpenblick TV", "de", 3), Triple("Hafenstadt HD", "de", 7), Triple("Ostsee Eins", "de", 0),
        Triple("Arena Sport 1 HD", "sport", 3), Triple("Arena Sport 2 HD", "sport", 3), Triple("Torjäger TV FHD", "sport", 1),
        Triple("Motorhaus 4K", "sport", 0), Triple("Matchball HD", "sport", 2), Triple("Kino Prime HD", "film", 7),
        Triple("Serienwerk HD", "film", 7), Triple("Nachtkino", "film", 0), Triple("Thrill+ FHD", "film", 3),
        Triple("Komödienhaus", "film", 2), Triple("Planet Wild HD", "doku", 7), Triple("Zeitreise TV", "doku", 3),
        Triple("Tiefsee Doku", "doku", 0), Triple("Wissen Plus HD", "doku", 7), Triple("Info 24 HD", "news", 7),
        Triple("Wirtschaft Live", "news", 1), Triple("Weltblick News", "news", 7), Triple("Kinderinsel", "kids", 3),
        Triple("Toonbox HD", "kids", 0), Triple("Lernzwerge", "kids", 0), Triple("Beat FM TV", "music", 0),
        Triple("Schlagerwelle", "music", 1), Triple("Club Visions HD", "music", 0),
    )

    private val titles = mapOf(
        "de" to listOf(
            "Guten Morgen Nord", "Küstenwache", "Die Rätselshow", "Tagesbild", "Wetter & Meer",
            "Hof der Familie Brandt", "Quiz um Zwölf", "Abendschau", "Der Landarzt von Lüttdorf",
            "Tatort Hafenkante", "Spätgespräch", "Unsere Heimat", "Kochen mit Klaus", "Talk am Kamin",
        ),
        "sport" to listOf(
            "Liga Live: Konferenz", "Sport am Abend", "Tennis: Halbfinale", "Motorsport Magazin",
            "Fußball: Highlights", "Basketball live", "Die Analyse", "Golf: Finalrunde", "Handball: Topspiel",
            "Boxen: Titelkampf", "Radsport: Etappe 14",
        ),
        "film" to listOf(
            "Der letzte Sommer", "Schatten über Brennberg", "Nachtzug nach Riga", "Der Leuchtturmwärter",
            "Kalter Atem", "Das Haus am See", "Zwischen den Zeilen", "Grenzgänger", "Die Akte Lorenz",
            "Herzklopfen in Hamburg", "Funkstille", "Stille Wasser",
        ),
        "doku" to listOf(
            "Wilde Wälder Europas", "Geheimnisse der Tiefsee", "Das Römische Reich", "Planet der Insekten",
            "Mega-Bauwerke", "Die Arktis im Wandel", "Leben in der Savanne", "Kosmos – Reise zu den Sternen",
            "Vulkane: Feuer der Erde", "Die Seidenstraße",
        ),
        "news" to listOf(
            "Nachrichten", "Wirtschaft kompakt", "Weltjournal", "Börse am Mittag", "Brennpunkt",
            "Das Interview", "Nachrichten am Abend", "Wetter",
        ),
        "kids" to listOf(
            "Fuchs & Freunde", "Die Weltraumkatze", "Bastelzeit", "Ritter Rudi", "Das Wissensboot",
            "Pixel Piraten", "Gute-Nacht-Geschichte",
        ),
        "music" to listOf(
            "Top 40 Countdown", "Club Session", "Schlager-Hits", "Live im Studio", "Nachtmix",
            "90er Classics", "Unplugged",
        ),
    )

    private val genres = mapOf(
        "de" to "Unterhaltung", "sport" to "Sport", "film" to "Spielfilm", "doku" to "Dokumentation",
        "news" to "Nachrichten", "kids" to "Kinder", "music" to "Musik",
    )

    val channels: List<Channel> = defs.mapIndexed { i, (name, cat, days) ->
        Channel(
            id = "demo_$i", name = name, categoryId = cat, streamUrl = TEST_STREAM,
            epgId = "demo_$i", catchupDays = days, number = i + 1,
        )
    }

    private fun describe(title: String, cat: String) = when (cat) {
        "sport" -> "Live-Übertragung mit Vorberichten, Analysen und allen Höhepunkten. Moderation aus dem Studio, Kommentar vom Spielfeldrand."
        "film" -> "„$title“ – ein Drama über Schuld, Vertrauen und einen Sommer, der alles verändert. Mit viel Atmosphäre und starken Darstellern."
        "doku" -> "Eine Reise mit spektakulären Aufnahmen und Experten, die erklären, wie unsere Welt funktioniert."
        "news" -> "Aktuelle Meldungen aus Deutschland und der Welt, mit Wetter."
        "kids" -> "Spannende Abenteuer und Geschichten für Kinder ab 4 Jahren."
        "music" -> "Die besten Songs und Live-Auftritte, präsentiert von unseren Moderatoren."
        else -> "Unterhaltung für die ganze Familie."
    }

    /** Programm von 26 Std. zurück bis 30 Std. voraus (deterministisch je Sender). */
    fun epg(now: Long = System.currentTimeMillis()): Map<String, List<EpgEntry>> {
        val cal = Calendar.getInstance()
        cal.timeInMillis = now
        cal.set(Calendar.MINUTE, 0); cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        val anchor = cal.timeInMillis - 26L * 3600_000
        val end = now + 30L * 3600_000
        val out = LinkedHashMap<String, List<EpgEntry>>()
        for (c in channels) {
            val rnd = Random(c.id.hashCode().toLong())
            val list = titles.getValue(c.categoryId)
            var t = anchor + rnd.nextInt(4) * 15L * 60_000
            val l = ArrayList<EpgEntry>()
            while (t < end) {
                val len = when (c.categoryId) {
                    "news" -> intArrayOf(15, 30, 30, 45)[rnd.nextInt(4)]
                    "film" -> intArrayOf(90, 105, 120, 45)[rnd.nextInt(4)]
                    "kids" -> intArrayOf(25, 30, 30)[rnd.nextInt(3)]
                    else -> intArrayOf(30, 45, 60, 60, 90)[rnd.nextInt(5)]
                }
                val title = list[rnd.nextInt(list.size)]
                val e = t + len * 60_000L
                l.add(EpgEntry(c.epgId!!, title, t, e, describe(title, c.categoryId), genres[c.categoryId]))
                t = e
            }
            out[c.epgId!!] = l
        }
        return out
    }

    fun catchupUrl(c: Channel): String? = if (c.catchupDays > 0) TEST_STREAM else null
}
