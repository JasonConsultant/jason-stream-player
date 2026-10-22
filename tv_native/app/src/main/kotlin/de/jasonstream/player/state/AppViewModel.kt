package de.jasonstream.player.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.MyGroup
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.security.Redactor
import de.jasonstream.core.storage.Storage
import de.jasonstream.core.ui.AppPalette
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import de.jasonstream.data.channels.VariantGroup
import de.jasonstream.data.channels.groupVariants
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.data.epg.epgKeyOf
import de.jasonstream.player.logic.EpgIndex
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.LivePrefs
import de.jasonstream.player.logic.LiveSnapshot
import de.jasonstream.player.logic.RawLive
import de.jasonstream.player.logic.RecentSearches
import de.jasonstream.player.logic.ShellNav
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.playback.api.PlayRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Lade-Zustand der Senderliste / des EPG. */
data class LoadStatus(
    val loadingList: Boolean = false,
    val loadingEpg: Boolean = false,
    val error: String? = null,
    val noPortal: Boolean = false,
)

/** Offene PIN-Abfrage (Dialog). */
class PinRequest(val reason: String, val create: Boolean, val result: CompletableDeferred<Boolean>)

/** Kurze Meldung unten (wie SnackBar). */
data class UiMessage(val text: String, val id: Long = System.nanoTime())

/**
 * Zustand der ganzen TV-Oberfläche. Getrennte StateFlows, damit z. B. ein
 * neues EPG nicht die Senderliste neu zeichnet und umgekehrt.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModel(
    private val env: AppEnv,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val compute: CoroutineDispatcher = Dispatchers.Default,
    autoStart: Boolean = true,
    private val clock: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    /** Eine Warteschlange für Neuaufbau der Liste (nie zwei gleichzeitig). */
    private val builder = compute.limitedParallelism(1)

    private val _shell = MutableStateFlow(ShellState())
    val shell: StateFlow<ShellState> = _shell.asStateFlow()

    private val _portals = MutableStateFlow<List<Portal>>(emptyList())
    val portals: StateFlow<List<Portal>> = _portals.asStateFlow()
    private val _portal = MutableStateFlow<Portal?>(null)
    val portal: StateFlow<Portal?> = _portal.asStateFlow()

    private val _live = MutableStateFlow(LiveSnapshot.empty)
    val live: StateFlow<LiveSnapshot> = _live.asStateFlow()

    private val _epg = MutableStateFlow(EpgIndex.EMPTY)
    val epg: StateFlow<EpgIndex> = _epg.asStateFlow()
    private val _epgRevision = MutableStateFlow(0L)
    val epgRevision: StateFlow<Long> = _epgRevision.asStateFlow()

    private val _status = MutableStateFlow(LoadStatus(loadingList = autoStart))
    val status: StateFlow<LoadStatus> = _status.asStateFlow()

    private val _accent = MutableStateFlow(AppPalette.DEFAULT_ACCENT)
    val accent: StateFlow<String> = _accent.asStateFlow()

    /** Was der Player gerade spielt (null = nichts gestartet). */
    private val _request = MutableStateFlow<PlayRequest?>(null)
    val request: StateFlow<PlayRequest?> = _request.asStateFlow()

    /** Zuletzt gesehener/gewählter Sender (Startseite, Mini-Video im Guide). */
    private val _current = MutableStateFlow<Channel?>(null)
    val current: StateFlow<Channel?> = _current.asStateFlow()

    private val _message = MutableStateFlow<UiMessage?>(null)
    val message: StateFlow<UiMessage?> = _message.asStateFlow()

    private val _pin = MutableStateFlow<PinRequest?>(null)
    val pin: StateFlow<PinRequest?> = _pin.asStateFlow()

    /** Live TV über das Menü geöffnet → Senderliste zeigen; über „Ansehen“ → nur Video. */
    private val _liveOverlayOnEnter = MutableStateFlow(true)
    val liveOverlayOnEnter: StateFlow<Boolean> = _liveOverlayOnEnter.asStateFlow()
    fun setLiveOverlayOnEnter(v: Boolean) { _liveOverlayOnEnter.value = v }

    /** Gruppe im TV-Guide (für die Dauer der Sitzung). */
    @Volatile
    var lastGuideGroup: String? = null

    /** Erinnerungen (Platzhalter bis zur Phase „Erinnerungen“): Sender-ID → Startzeiten. */
    val reminders = ConcurrentHashMap<String, MutableSet<Long>>()

    /** Zuletzt gewählte Gruppe der Senderliste (für die Dauer der Sitzung). */
    @Volatile
    var lastLiveGroup: String? = null

    /** Vorbelegter Suchbegriff (Sprachsuche von außen, Bildschirmfotos). */
    @Volatile
    var pendingSearch: String? = null

    private val _recentSearches = MutableStateFlow<List<String>>(emptyList())
    val recentSearches: StateFlow<List<String>> = _recentSearches.asStateFlow()

    @Volatile
    var storage: Storage? = null
        private set
    private var repo: IptvRepository? = null
    private var raw: RawLive? = null
    private var variantGroups: List<VariantGroup>? = null
    private var listJob: Job? = null
    private var epgJob: Job? = null
    private var rebuildJob: Job? = null
    private val shortEpg = ConcurrentHashMap<String, List<EpgEntry>>()
    private val shortEpgAsked = ConcurrentHashMap.newKeySet<String>()

    init {
        if (autoStart) viewModelScope.launch { start() }
    }

    // ------------------------------------------------------------ Laden

    private suspend fun start() {
        val st = withContext(io) {
            runCatching { env.migrate() }
            env.openStorage()
        }
        attach(st)
        val p = st.activePortal()
        if (p == null) {
            _status.value = LoadStatus(noPortal = true)
            return
        }
        loadPortal(p)
    }

    /** Speicher übernehmen (auch für Tests/Bildschirmfotos). */
    fun attach(st: Storage) {
        storage = st
        _portals.value = st.portals()
        _accent.value = st.option("accent", AppPalette.DEFAULT_ACCENT)
            .takeIf { it in AppPalette.accentPresets } ?: AppPalette.DEFAULT_ACCENT
        // „Beim Öffnen zeigen“: Startseite oder direkt Live TV (wie die Flutter-App).
        if (st.option("starttab", "home") == "live" && _shell.value == ShellState()) {
            _shell.value = ShellState(Tab.Live, Zone.Content)
        }
    }

    private fun loadPortal(p: Portal) {
        listJob?.cancel()
        epgJob?.cancel()
        shortEpg.clear(); shortEpgAsked.clear()
        _portal.value = p
        _recentSearches.value = readRecentSearches(p)
        listJob = viewModelScope.launch { loadList(p) }
    }

    private suspend fun loadList(p: Portal) {
        val st = storage ?: return
        _status.value = LoadStatus(loadingList = true)
        val r = env.repositoryFor(p)
        repo = r
        // 1. Zwischenspeicher (nativ oder Flutter) → sofort anzeigen.
        var prevHash: String? = null
        val cache = env.listCache
        if (cache != null && p.type != PortalType.demo) {
            val cached = withContext(io) {
                runCatching {
                    cache.loadLive(p) ?: env.flutterFilesDir?.let { dir ->
                        cache.importFlutterLive(dir, p)?.also { imp ->
                            runCatching { cache.storeLive(p, LiveList(imp.categories, imp.items), savedMs = imp.savedMs) }
                        }
                    }
                }.getOrNull()
            }
            if (cached != null) {
                prevHash = cached.hash
                setRaw(RawLive(cached.categories, cached.items))
            }
        }
        // 2. Netz.
        try {
            val live = withContext(io) {
                val l = r.live()
                if (cache != null && p.type != PortalType.demo) {
                    val stored = runCatching { cache.storeLive(p, l, prevHash) }.getOrNull()
                    st.setListRefreshed(p.id, clock())
                    if (stored?.unchanged == true && raw != null) null else l
                } else l
            }
            if (live != null) setRaw(RawLive(live.categories, live.channels))
            _status.update { it.copy(loadingList = false, error = null) }
        } catch (e: Exception) {
            val msg = Redactor.redact(e.message ?: e.javaClass.simpleName)
            _status.update { it.copy(loadingList = false, error = msg) }
        }
        loadEpg(p)
    }

    private fun loadEpg(p: Portal) {
        val r = repo ?: return
        val channels = raw?.channels ?: return
        epgJob?.cancel()
        epgJob = viewModelScope.launch {
            _status.update { it.copy(loadingEpg = true) }
            try {
                val map = withContext(io) { EpgWindow.cap(r.loadEpg(channels), clock()) }
                _epg.value = EpgIndex(map, shortEpg)
                _epgRevision.update { it + 1 }
                storage?.setEpgUpdated(p.id, clock())
            } catch (_: Exception) {
                // EPG ist optional; Kurz-EPG springt pro Sender ein.
            }
            _status.update { it.copy(loadingEpg = false) }
        }
    }

    private suspend fun setRaw(r: RawLive) {
        raw = r
        variantGroups = null
        rebuild()
        if (_current.value == null) pickInitialChannel()
    }

    /** Liste neu aufbauen (Einstellungen, Favoriten, Verlauf …) – im Hintergrund. */
    private suspend fun rebuild() {
        val r = raw ?: return
        val st = storage ?: return
        val p = _portal.value ?: return
        val snap = withContext(builder) {
            val prefs = readPrefs(st, p, r)
            val vg = if (prefs.mergeVariants) {
                variantGroups ?: run {
                    val all = if (prefs.overrides.isEmpty()) r.channels
                    else r.channels.map { c -> prefs.overrides[c.id]?.let { c.withOverride(it) } ?: c }
                    groupVariants(all).also { variantGroups = it }
                }
            } else null
            // Gruppen/Zähler schon hier (Hintergrund) berechnen, nicht beim ersten Zeichnen.
            LiveSnapshot.build(r, prefs, vg).also { it.groups; it.channelsOf(GroupIds.ALL); it.channelsOf(GroupIds.FAV) }
        }
        _live.value = snap
    }

    private fun scheduleRebuild() {
        rebuildJob?.cancel()
        rebuildJob = viewModelScope.launch { rebuild() }
    }

    private fun readPrefs(st: Storage, p: Portal, r: RawLive): LivePrefs {
        val my = st.myGroups(p.id)
        val orders = HashMap<String, List<String>>()
        for (id in r.categories.map { it.id } + my.map { it.id } + listOf(GroupIds.FAV, GroupIds.ALL)) {
            val o = st.channelOrder(p.id, id)
            if (o.isNotEmpty()) orders[id] = o
        }
        return LivePrefs(
            hidden = st.hidden(p.id),
            hiddenGroups = st.hiddenGroups(p.id),
            overrides = st.overrides(p.id),
            favorites = st.favorites(p.id),
            locked = st.locked(p.id),
            recents = st.recent(p.id),
            myGroups = my,
            groupOrder = st.groupOrder(p.id),
            channelOrders = orders,
            mergeVariants = st.flag("mergevariants", fallback = true),
            variantChoice = variantChoices(st, p.id),
            countries = st.countries(p.id),
            kids = st.kidsMode,
            kidsGroups = st.kidsGroups(p.id),
            guest = st.guestMode,
        )
    }

    private fun variantChoices(st: Storage, portalId: String): Map<String, String> = try {
        (Json.parseToJsonElement(st.option("varpick_$portalId", "{}")) as? JsonObject)
            ?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.let { k to it.content } }
            ?.toMap() ?: emptyMap()
    } catch (_: Exception) {
        emptyMap()
    }

    /** Letzter Sender (oder erster Favorit / erster Sender) für Startseite und Live TV. */
    private fun pickInitialChannel() {
        val st = storage ?: return
        val p = _portal.value ?: return
        val snap = _live.value
        val last = st.lastChannel(p.id)?.let { snap.byId[it] ?: snap.byId[snap.variants.representativeOf(it)] }
        _current.value = last ?: snap.recentChannels.firstOrNull() ?: snap.favoriteChannels.firstOrNull()
            ?: snap.channels.firstOrNull()
    }

    /** Für Bildschirmfotos/Tests: Daten direkt setzen (ohne Netz). */
    suspend fun setDataForPreview(p: Portal, r: RawLive, epg: Map<String, List<EpgEntry>>, current: String? = null) {
        _portal.value = p
        _recentSearches.value = readRecentSearches(p)
        raw = r
        repo = env.repositoryFor(p)
        rebuild()
        _epg.value = EpgIndex(epg, shortEpg)
        _current.value = current?.let { _live.value.byId[it] } ?: _live.value.channels.firstOrNull()
        _status.value = LoadStatus()
    }

    // ------------------------------------------------------------ EPG

    /** Zeile zeigt [c] ohne EPG → Kurz-EPG vom Portal holen (einmal je Sender). */
    fun wantEpg(c: Channel) {
        if (_epg.value.has(c)) return
        val r = repo ?: return
        val key = epgKeyOf(c)
        if (!shortEpgAsked.add(key)) return
        viewModelScope.launch {
            val l = withContext(io) { runCatching { r.shortEpg(c) }.getOrDefault(emptyList()) }
            if (l.isNotEmpty()) {
                shortEpg[key] = l.sortedBy { it.startMs }
                _epgRevision.update { it + 1 }
            }
        }
    }

    // ------------------------------------------------------------ Navigation

    fun setShell(s: ShellState) { _shell.value = s }
    fun selectTab(t: Tab) = _shell.update { ShellNav.select(it, t) }
    fun openTab(t: Tab) = _shell.update { ShellNav.open(it, t) }

    /** Menüpunkt gewählt (OK/▼). Live TV zeigt dann die Senderliste. */
    fun openFromMenu(t: Tab) {
        if (t == Tab.Live) _liveOverlayOnEnter.value = true
        openTab(t)
    }
    fun setZone(z: Zone) = _shell.update { if (it.zone == z) it else it.copy(zone = z, exitArmedAt = null) }

    /** Zurück-Taste auf Shell-Ebene. true = App beenden. */
    fun back(exitHint: String): Boolean {
        val r = ShellNav.back(_shell.value, clock())
        _shell.value = r.state
        return when (r.effect) {
            ShellNav.Effect.Exit -> true
            ShellNav.Effect.ShowExitHint -> { toast(exitHint); false }
            ShellNav.Effect.None -> false
        }
    }

    fun toast(text: String) { _message.value = UiMessage(text) }
    fun clearMessage(m: UiMessage) { _message.compareAndSet(m, null) }

    // ------------------------------------------------------------ Abspielen

    /**
     * Sender abspielen (Liste = Zapp-Reihenfolge). Gesperrte Sender
     * verlangen die PIN. [openLive]: zu Live TV wechseln.
     */
    fun play(c: Channel, list: List<Channel>, pinText: String, openLive: Boolean = true) {
        val p = _portal.value ?: return
        viewModelScope.launch {
            if (_live.value.isLocked(c) && !confirmPin(pinText)) return@launch
            val l = list.ifEmpty { listOf(c) }
            val idx = l.indexOfFirst { it.id == c.id }.coerceAtLeast(0)
            _current.value = c
            _request.value = PlayRequest.live(p.id, if (idx < l.size && l[idx].id == c.id) l else listOf(c), idx)
            if (openLive) {
                _liveOverlayOnEnter.value = false
                openTab(Tab.Live)
            }
        }
    }

    /** Sendung aus dem Archiv. */
    fun playCatchup(c: Channel, e: EpgEntry, pinText: String) {
        val p = _portal.value ?: return
        viewModelScope.launch {
            if (_live.value.isLocked(c) && !confirmPin(pinText)) return@launch
            _current.value = c
            _request.value = PlayRequest.catchup(p.id, c, e, channels = _live.value.channelsOf(GroupIds.ALL))
            _liveOverlayOnEnter.value = false
            openTab(Tab.Live)
        }
    }

    /** Live TV ohne Auswahl: letzter Sender. */
    fun ensureLiveRequest(pinText: String) {
        if (_request.value != null) return
        val c = _current.value ?: return
        val snap = _live.value
        val list = snap.recentChannels.takeIf { r -> r.any { it.id == c.id } }?.let { snap.channelsOf(GroupIds.ALL) }
            ?: snap.channelsOf(GroupIds.ALL)
        play(c, list, pinText, openLive = false)
    }

    /** Der Player hat intern gezappt. */
    fun onRequestChanged(r: PlayRequest) {
        _request.value = r
        r.channels.getOrNull(r.index)?.let { _current.value = it }
    }

    /** OK auf einer künftigen Sendung (Erinnerung – Stub). */
    fun remind(c: Channel, e: EpgEntry?, text: String) {
        if (e == null) return
        reminders.getOrPut(c.id) { ConcurrentHashMap.newKeySet() }.add(e.startMs)
        toast(text)
    }

    fun onChannelStarted() = scheduleRebuild() // „Zuletzt gesehen“ aktualisieren

    // ------------------------------------------------------------ PIN

    fun hasPin() = storage?.hasPin() == true

    /** PIN-Dialog anzeigen und auf das Ergebnis warten (ohne PIN → frei). */
    suspend fun confirmPin(reason: String, create: Boolean = false): Boolean {
        if (!create && !hasPin()) return true
        val d = CompletableDeferred<Boolean>()
        _pin.value = PinRequest(reason, create, d)
        return try { d.await() } finally { _pin.value = null }
    }

    fun verifyPin(pin: String): Storage.PinResult = storage?.verifyPin(pin) ?: Storage.PinResult.Ok

    // ------------------------------------------------------------ Sender-Aktionen

    fun toggleFavorite(c: Channel, added: String, removed: String) {
        val st = storage ?: return
        val p = _portal.value ?: return
        if (st.guestMode) return
        val was = c.id in st.favorites(p.id)
        st.toggleFavorite(p.id, c.id)
        toast(if (was) removed else added)
        scheduleRebuild()
    }

    fun toggleLock(c: Channel, pinText: String) {
        val st = storage ?: return
        val p = _portal.value ?: return
        viewModelScope.launch {
            // Erstes Sperren ohne PIN → PIN anlegen (wie die Flutter-App).
            if (!confirmPin(pinText, create = !st.hasPin())) return@launch
            st.toggleLocked(p.id, c.id)
            rebuild()
        }
    }

    fun setPin(pin: String) { storage?.setPin(pin) }

    fun hideChannel(c: Channel, message: String) {
        val st = storage ?: return
        val p = _portal.value ?: return
        st.toggleHidden(p.id, c.id)
        toast(message)
        scheduleRebuild()
    }

    fun chooseVariant(c: Channel) {
        val st = storage ?: return
        val p = _portal.value ?: return
        val g = _live.value.variantGroup(c) ?: return
        val next = variantChoices(st, p.id).toMutableMap()
        if (g.best.id == c.id) next.remove(g.key) else next[g.key] = c.id
        st.setOption("varpick_${p.id}", JsonObject(next.mapValues { JsonPrimitive(it.value) }).toString())
        scheduleRebuild()
    }

    fun toggleInGroup(c: Channel, groupId: String) {
        val st = storage ?: return
        val p = _portal.value ?: return
        val groups = st.myGroups(p.id).map { g ->
            if (g.id != groupId) g
            else g.copy(channels = if (c.id in g.channels) g.channels - c.id else g.channels + c.id)
        }
        st.setMyGroups(p.id, groups)
        scheduleRebuild()
    }

    fun createGroup(name: String, first: Channel?): String? {
        val st = storage ?: return null
        val p = _portal.value ?: return null
        val n = name.trim().ifEmpty { return null }
        val g = MyGroup(MyGroup.PREFIX + UUID.randomUUID().toString().substring(0, 8), n, listOfNotNull(first?.id))
        st.setMyGroups(p.id, st.myGroups(p.id) + g)
        scheduleRebuild()
        return g.id
    }

    fun clearRecent() {
        val st = storage ?: return
        val p = _portal.value ?: return
        st.clearRecent(p.id)
        scheduleRebuild()
    }

    // ------------------------------------------------------------ Suche

    private fun readRecentSearches(p: Portal): List<String> {
        val st = storage ?: return emptyList()
        if (st.guestMode) return emptyList()
        return try {
            (Json.parseToJsonElement(st.option("recentsearch_${p.id}", "[]")) as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.content?.takeIf { s -> s.isNotBlank() } }
                ?.take(RecentSearches.MAX) ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun saveRecentSearches(l: List<String>) {
        val st = storage ?: return
        val p = _portal.value ?: return
        if (st.guestMode) return
        _recentSearches.value = l
        st.setOption("recentsearch_${p.id}", JsonArray(l.map { JsonPrimitive(it) }).toString())
    }

    fun addRecentSearch(q: String) = saveRecentSearches(RecentSearches.add(_recentSearches.value, q))
    fun removeRecentSearch(q: String) = saveRecentSearches(RecentSearches.remove(_recentSearches.value, q))
    fun clearRecentSearches() = saveRecentSearches(emptyList())

    // ------------------------------------------------------------ Einstellungen

    val versionName: String get() = env.versionName

    fun option(key: String, fallback: String) = storage?.option(key, fallback) ?: fallback
    fun flag(key: String, fallback: Boolean = false) = storage?.flag(key, fallback) ?: fallback

    fun setOption(key: String, v: String) {
        storage?.setOption(key, v)
        if (key == "accent") _accent.value = v
    }

    fun setFlag(key: String, v: Boolean) {
        storage?.setFlag(key, v)
        if (key in setOf("mergevariants", "guest", "kids")) {
            variantGroups = variantGroups.takeIf { key != "mergevariants" }
            scheduleRebuild()
        }
    }

    fun switchPortal(p: Portal) {
        val st = storage ?: return
        if (p.id == _portal.value?.id) return
        st.setActivePortal(p.id)
        _request.value = null
        _current.value = null
        _live.value = LiveSnapshot.empty
        _epg.value = EpgIndex.EMPTY
        raw = null
        loadPortal(p)
    }

    /** „Demo ausprobieren“ (kein Portal eingerichtet). */
    fun addDemoPortal() {
        val st = storage ?: return
        st.addPortal(Portal.demo)
        st.setActivePortal(Portal.demo.id)
        _portals.value = st.portals()
        loadPortal(Portal.demo)
    }

    fun reload() {
        val p = _portal.value ?: return
        loadPortal(p)
    }

    /** Für den Player: aktuelles Repository (Adressen, Catch-up). */
    fun repository(): IptvRepository? = repo

    /** Nach 2,5 s ausblenden. */
    suspend fun autoHide(m: UiMessage) {
        delay(2500)
        clearMessage(m)
    }
}
