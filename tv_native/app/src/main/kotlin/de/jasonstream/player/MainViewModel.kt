package de.jasonstream.player

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.jasonstream.core.migration.FlutterMigration
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.security.Redactor
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Zustand der Startseite (Phase 1: Nachweis Migration → Liste). */
data class HomeState(
    val step: String = "Start …",
    val migration: FlutterMigration.Report? = null,
    val portals: List<Portal> = emptyList(),
    val portal: Portal? = null,
    val categories: List<Category> = emptyList(),
    /** Kategorie-ID → Sender (in Anbieter-Reihenfolge). */
    val byCategory: Map<String, List<Channel>> = emptyMap(),
    val channelCount: Int = 0,
    val favorites: Int = 0,
    val source: String? = null,
    val savedMs: Long? = null,
    val loading: Boolean = true,
    val error: String? = null,
    val unreadableSecrets: Int = 0,
)

class MainViewModel(private val c: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(HomeState())
    val state: StateFlow<HomeState> = _state
    private var job: Job? = null

    init {
        job = viewModelScope.launch { start() }
    }

    private suspend fun start() {
        _state.update { it.copy(step = "Daten übernehmen …") }
        val report = withContext(Dispatchers.IO) {
            runCatching { c.migrate() }.getOrNull()
            c.migrationReport()
        }
        _state.update { it.copy(migration = report, step = "Speicher öffnen …") }
        val storage = withContext(Dispatchers.IO) { c.openStorage() }
        val portals = storage.portals()
        val portal = storage.activePortal()
        _state.update {
            it.copy(portals = portals, portal = portal, unreadableSecrets = storage.unreadableSecrets)
        }
        if (portal == null) {
            _state.update { it.copy(loading = false, step = "", error = "Kein Portal vorhanden (Einrichtung folgt in Phase 2).") }
            return
        }
        load(portal, network = true)
    }

    /** Liste aus dem Zwischenspeicher (nativ oder Flutter), danach aus dem Netz. */
    private suspend fun load(portal: Portal, network: Boolean) {
        val storage = c.openStorage()
        _state.update {
            it.copy(portal = portal, loading = true, error = null, step = "Zwischenspeicher lesen …",
                favorites = storage.favorites(portal.id).size)
        }
        if (portal.type == PortalType.demo) {
            _state.update { it.copy(loading = false, step = "", error = "Demo-Portal folgt in Phase 2.") }
            return
        }
        val cached = withContext(Dispatchers.IO) {
            c.listCache.loadLive(portal)?.let { it to "Zwischenspeicher" }
                ?: c.listCache.importFlutterLive(c.flutterFilesDir, portal)?.let { imported ->
                    // Einmal ins native Format übernehmen.
                    runCatching {
                        c.listCache.storeLive(portal, LiveList(imported.categories, imported.items), savedMs = imported.savedMs)
                    }
                    imported to "Flutter-Zwischenspeicher"
                }
        }
        var prevHash: String? = null
        if (cached != null) {
            val (list, src) = cached
            prevHash = list.hash
            show(LiveList(list.categories, list.items), src, list.savedMs)
        }
        if (!network) {
            _state.update { it.copy(loading = false, step = "") }
            return
        }
        _state.update { it.copy(step = "Senderliste laden …") }
        try {
            val (live, stored) = withContext(Dispatchers.IO) {
                val repo = IptvRepository.forPortal(portal)
                val l = repo.live()
                val st = runCatching { c.listCache.storeLive(portal, l, prevHash) }.getOrNull()
                storage.setListRefreshed(portal.id, System.currentTimeMillis())
                l to st
            }
            if (stored?.unchanged == true && cached != null) {
                _state.update { it.copy(source = "Netz (unverändert)", savedMs = System.currentTimeMillis()) }
            } else {
                show(live, "Netz", System.currentTimeMillis())
            }
            _state.update { it.copy(loading = false, step = "") }
        } catch (e: Exception) {
            val msg = Redactor.redact(e.message ?: e.javaClass.simpleName)
            _state.update { it.copy(loading = false, step = "", error = if (cached != null) "Aktualisierung fehlgeschlagen: $msg" else msg) }
        }
    }

    /** Gruppieren/Filtern abseits des Haupt-Threads (50 000+ Sender). */
    private suspend fun show(l: LiveList, source: String, savedMs: Long) = withContext(Dispatchers.Default) {
        val storage = c.openStorage()
        val portal = _state.value.portal ?: return@withContext
        val hiddenGroups = storage.hiddenGroups(portal.id)
        val hidden = storage.hidden(portal.id)
        val byCat = LinkedHashMap<String, MutableList<Channel>>()
        val overrides = storage.overrides(portal.id)
        for (ch in l.channels) {
            if (ch.id in hidden) continue
            byCat.getOrPut(ch.categoryId) { ArrayList() }.add(ch.withOverride(overrides[ch.id]))
        }
        // Eigene Gruppen-Reihenfolge der Flutter-App übernehmen.
        val order = storage.groupOrder(portal.id)
        val cats = l.categories.filter { it.id !in hiddenGroups && byCat.containsKey(it.id) }
            .sortedBy { order.indexOf(it.id).let { i -> if (i < 0) Int.MAX_VALUE else i } }
        val favIds = storage.favorites(portal.id)
        val byId = if (favIds.isEmpty()) emptyMap() else l.channels.associateBy { it.id }
        val favs = favIds.mapNotNull { byId[it]?.withOverride(overrides[it]) }
        val withFav = if (favs.isEmpty()) cats else listOf(Category(FAV_ID, "★ Favoriten")) + cats
        if (favs.isNotEmpty()) byCat[FAV_ID] = favs.toMutableList()
        _state.update {
            it.copy(
                categories = withFav, byCategory = byCat, channelCount = l.channels.size,
                source = source, savedMs = savedMs, favorites = favIds.size,
            )
        }
    }

    fun refresh() {
        val p = _state.value.portal ?: return
        job?.cancel()
        job = viewModelScope.launch { load(p, network = true) }
    }

    /** Nächstes Portal (wird wie in der Flutter-App als aktiv gemerkt). */
    fun nextPortal() {
        val s = _state.value
        if (s.portals.size < 2) return
        val i = s.portals.indexOfFirst { it.id == s.portal?.id }
        val next = s.portals[(i + 1) % s.portals.size]
        job?.cancel()
        job = viewModelScope.launch {
            withContext(Dispatchers.IO) { c.openStorage().setActivePortal(next.id) }
            _state.update { it.copy(categories = emptyList(), byCategory = emptyMap(), channelCount = 0, source = null) }
            load(next, network = true)
        }
    }

    companion object {
        const val FAV_ID = "__fav"
    }
}
