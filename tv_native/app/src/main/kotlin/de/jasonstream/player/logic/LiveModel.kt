package de.jasonstream.player.logic

import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.ChannelOverride
import de.jasonstream.core.model.MyGroup
import de.jasonstream.data.channels.CountryDetector
import de.jasonstream.data.channels.VariantGroup
import de.jasonstream.data.channels.VariantIndex
import de.jasonstream.data.channels.groupVariants

/** Feste Gruppen-IDs (wie live_screen.dart). */
object GroupIds {
    const val FAV = "__fav"
    const val ALL = "__all"
    const val RECENT = "__recent"
}

enum class GroupKind { Favorites, Recent, My, Provider, All }

/** Ein Eintrag der Gruppenspalte. [name] ist bei festen Gruppen leer (Text aus Ressourcen). */
data class GroupEntry(val id: String, val name: String, val count: Int, val kind: GroupKind)

/**
 * Gespeicherte Reihenfolge (Port von SortOrder in providers.dart):
 * Bekannte IDs nach [order], Unbekannte behalten ihre Reihenfolge und
 * kommen ans Ende.
 */
object SortOrder {
    fun <T> apply(items: List<T>, order: List<String>, id: (T) -> String): List<T> {
        if (order.isEmpty() || items.size < 2) return items
        val pos = HashMap<String, Int>(order.size * 2)
        order.forEachIndexed { i, s -> pos.putIfAbsent(s, i) }
        val idx = items.indices.sortedWith { a, b ->
            val pa = pos[id(items[a])]
            val pb = pos[id(items[b])]
            when {
                pa != null && pb != null -> pa.compareTo(pb)
                pa != null -> -1
                pb != null -> 1
                else -> a.compareTo(b)
            }
        }
        return idx.map { items[it] }
    }
}

/** Alles aus dem Speicher, was die sichtbare Senderliste bestimmt. */
data class LivePrefs(
    val hidden: Set<String> = emptySet(),
    val hiddenGroups: Set<String> = emptySet(),
    val overrides: Map<String, ChannelOverride> = emptyMap(),
    val favorites: Set<String> = emptySet(),
    val locked: Set<String> = emptySet(),
    val recents: List<String> = emptyList(),
    val myGroups: List<MyGroup> = emptyList(),
    val groupOrder: List<String> = emptyList(),
    val channelOrders: Map<String, List<String>> = emptyMap(),
    val mergeVariants: Boolean = true,
    val variantChoice: Map<String, String> = emptyMap(),
    val countries: Set<String> = emptySet(),
    val kids: Boolean = false,
    val kidsGroups: Set<String> = emptySet(),
    val guest: Boolean = false,
)

/**
 * Unveränderliche, fertig gefilterte Senderliste für die Oberfläche
 * (im Hintergrund gebaut). Pipeline wie in der Flutter-App:
 * Überschreibungen → Varianten zusammenfassen → Länderfilter →
 * Kindermodus; versteckte Sender fehlen überall.
 */
class LiveSnapshot private constructor(
    val categories: List<Category>,
    val channels: List<Channel>,
    val prefs: LivePrefs,
    val variants: VariantIndex,
    /** Alle Sender (mit Überschreibungen), auch verdeckte Varianten. */
    val allById: Map<String, Channel>,
    val myGroups: List<MyGroup>,
) {
    val byId: Map<String, Channel> = HashMap<String, Channel>(channels.size * 2).also { m ->
        for (c in channels) m[c.id] = c
    }
    private val catName: Map<String, String> = categories.associate { it.id to it.name }
    private val byCategory: Map<String, List<Channel>> = channels.groupBy { it.categoryId }
    private val memo = HashMap<String, List<Channel>>()

    val favorites: Set<String> get() = prefs.favorites
    val locked: Set<String> get() = prefs.locked
    val guest: Boolean get() = prefs.guest

    fun categoryName(id: String): String? = catName[id]

    fun isFavorite(c: Channel) = c.id in prefs.favorites
    fun isLocked(c: Channel) = c.id in prefs.locked
    fun variantCount(c: Channel) = variants.countOf(c.id)
    fun variantGroup(c: Channel): VariantGroup? = variants.groupOf(c.id)

    /** Abspielreihenfolge: gewählte Variante, dann nach Qualität. */
    fun playOrder(c: Channel): List<Channel> {
        val g = variants.groupOf(c.id) ?: return listOf(c)
        return g.playOrder(prefs.variantChoice[g.key])
    }

    /** Zuletzt gesehene Sender (neueste zuerst; Varianten über den Vertreter). */
    val recentChannels: List<Channel> by lazy {
        if (prefs.guest) emptyList() else variants.resolve(prefs.recents, byId)
    }

    val favoriteChannels: List<Channel> get() = channelsOf(GroupIds.FAV)

    /** Gruppenspalte: Favoriten, Zuletzt gesehen, eigene Gruppen, Anbieter-Gruppen, Alle. */
    val groups: List<GroupEntry> by lazy {
        val out = ArrayList<GroupEntry>()
        if (!prefs.guest) {
            out.add(GroupEntry(GroupIds.FAV, "", channels.count { it.id in prefs.favorites }, GroupKind.Favorites))
            if (recentChannels.isNotEmpty()) {
                out.add(GroupEntry(GroupIds.RECENT, "", recentChannels.size, GroupKind.Recent))
            }
        }
        for (g in myGroups) out.add(GroupEntry(g.id, g.name, channelsOf(g.id).size, GroupKind.My))
        for (c in SortOrder.apply(categories, prefs.groupOrder) { it.id }) {
            if (c.id in prefs.hiddenGroups) continue
            val n = byCategory[c.id]?.size ?: 0
            if (n == 0) continue
            out.add(GroupEntry(c.id, c.name, n, GroupKind.Provider))
        }
        out.add(GroupEntry(GroupIds.ALL, "", channelsOf(GroupIds.ALL).size, GroupKind.All))
        out
    }

    /** Sender einer Gruppe (gemerkt; gleiche Liste bei gleicher Gruppe). */
    fun channelsOf(groupId: String): List<Channel> = synchronized(memo) {
        memo.getOrPut(groupId) { compute(groupId) }
    }

    private fun compute(groupId: String): List<Channel> = when {
        groupId == GroupIds.RECENT -> recentChannels
        groupId == GroupIds.FAV ->
            if (prefs.guest) emptyList()
            else SortOrder.apply(channels.filter { it.id in prefs.favorites }, prefs.channelOrders[GroupIds.FAV].orEmpty()) { it.id }
        MyGroup.isMy(groupId) -> {
            val g = myGroups.firstOrNull { it.id == groupId }
            if (g == null) emptyList()
            else SortOrder.apply(variants.resolve(g.channels, byId), prefs.channelOrders[g.id].orEmpty()) { it.id }
        }
        groupId == GroupIds.ALL -> {
            val l = if (prefs.hiddenGroups.isEmpty()) channels else channels.filter { it.categoryId !in prefs.hiddenGroups }
            SortOrder.apply(l, prefs.channelOrders[GroupIds.ALL].orEmpty()) { it.id }
        }
        else -> SortOrder.apply(byCategory[groupId].orEmpty(), prefs.channelOrders[groupId].orEmpty()) { it.id }
    }

    /** Anzeigenummer: Kanalnummer des Anbieters, sonst Position (1-basiert). */
    fun numberOf(c: Channel, position: Int): Int = if (c.number > 0) c.number else position + 1

    /** Sender per Kanalnummer (Direktwahl). */
    fun byNumber(n: Int): Channel? = channels.firstOrNull { it.number == n }

    companion object {
        val empty = LiveSnapshot(emptyList(), emptyList(), LivePrefs(), VariantIndex.empty, emptyMap(), emptyList())

        /**
         * [variantGroups]: bereits berechnete Varianten-Gruppen derselben Liste
         * (teuer bei großen Listen – bei Favoriten-/Verlaufsänderungen wiederverwenden).
         */
        fun build(raw: RawLive, p: LivePrefs, variantGroups: List<VariantGroup>? = null): LiveSnapshot {
            // 1. Überschreibungen
            val all = if (p.overrides.isEmpty()) raw.channels
            else raw.channels.map { c -> p.overrides[c.id]?.let { c.withOverride(it) } ?: c }
            val allById = HashMap<String, Channel>(all.size * 2).also { m -> for (c in all) m[c.id] = c }
            // 2. Varianten
            val idx = if (p.mergeVariants && all.size > 1) {
                VariantIndex.of(variantGroups ?: groupVariants(all), p.favorites, p.hidden, p.locked)
            } else VariantIndex.empty
            var visible = all.filter { it.id !in p.hidden }
            if (!idx.isEmpty) visible = idx.collapse(visible)
            var cats = raw.categories
            // 3. Länder
            if (p.countries.isNotEmpty()) {
                val gc = cats.associate { it.id to CountryDetector.fromGroup(it.name) }
                visible = visible.filter { CountryDetector.passes(CountryDetector.forItem(it.name, gc[it.categoryId]), p.countries) }
                val used = visible.mapTo(HashSet()) { it.categoryId }
                cats = cats.filter { it.id in used }
            }
            // 4. Kindermodus
            var my = p.myGroups
            if (p.kids) {
                val viaMy = HashSet<String>()
                for (g in p.myGroups) if (g.id in p.kidsGroups) for (id in g.channels) viaMy.add(idx.representativeOf(id))
                visible = visible.filter { it.categoryId in p.kidsGroups || it.id in viaMy }
                cats = cats.filter { it.id in p.kidsGroups }
                my = p.myGroups.filter { it.id in p.kidsGroups }
            }
            return LiveSnapshot(cats, visible, p, idx, allById, my)
        }
    }
}

/** Rohliste des Anbieters (Kategorien + Sender). */
data class RawLive(val categories: List<Category>, val channels: List<Channel>)
