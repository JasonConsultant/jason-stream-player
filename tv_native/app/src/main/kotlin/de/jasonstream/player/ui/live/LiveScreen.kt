package de.jasonstream.player.ui.live

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.Channel
import de.jasonstream.player.R as AppR
import de.jasonstream.player.logic.EpgIndex
import de.jasonstream.player.logic.GroupEntry
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.GroupKind
import de.jasonstream.player.logic.LiveSnapshot
import de.jasonstream.player.logic.SearchEngine
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.LocalShellFocus
import de.jasonstream.player.ui.PlayerHost
import de.jasonstream.player.ui.common.ChannelLogo
import de.jasonstream.player.ui.common.EmptyHint
import de.jasonstream.player.ui.common.EpgProgress
import de.jasonstream.player.ui.common.FavStar
import de.jasonstream.player.ui.common.Kicker
import de.jasonstream.player.ui.common.LocalNow
import de.jasonstream.player.ui.common.LockIcon
import de.jasonstream.player.ui.common.VariantBadge
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.hm
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.DpadTextField
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import kotlinx.coroutines.launch

/** Name einer Gruppe (feste Gruppen aus den Texten der App). */
@Composable
fun groupLabel(g: GroupEntry): String = when (g.kind) {
    GroupKind.Favorites -> stringResource(R.string.favouritesStarred)
    GroupKind.Recent -> stringResource(R.string.recentlyWatched)
    GroupKind.All -> stringResource(R.string.allChannels)
    else -> g.name
}

private fun fmtCount(n: Int): String = String.format(java.util.Locale.getDefault(), "%,d", n)

/**
 * Live TV (Entwurf a1): Video läuft im Vollbild (Player-Modul), links die
 * Senderliste als Overlay. Zurück blendet die Liste aus (Video bleibt),
 * noch einmal Zurück → Menü.
 */
@Composable
fun LiveScreen(vm: AppViewModel, player: PlayerHost, menuVisible: Boolean) {
    val request by vm.request.collectAsStateWithLifecycle()
    val pinText = stringResource(R.string.enterPin)
    val exitHint = stringResource(R.string.pressBackToExit)
    val showOverlayOnEnter by vm.liveOverlayOnEnter.collectAsStateWithLifecycle()
    var overlay by remember { mutableStateOf(showOverlayOnEnter) }
    val shell = LocalShellFocus.current

    LaunchedEffect(Unit) { vm.ensureLiveRequest(pinText) }
    // Aus dem Menü (▼) zurück in den Inhalt → Liste zeigen.
    LaunchedEffect(menuVisible) { if (!menuVisible && showOverlayOnEnter) overlay = true }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val r = request
        Box(Modifier.fillMaxSize().then(if (!overlay) Modifier.focusRequester(shell.content) else Modifier)) {
            if (r != null) {
                player.FullScreen(
                    request = r,
                    onExit = { vm.back(exitHint) },
                    onOpenGuide = { vm.openTab(Tab.Guide) },
                    onOpenChannelList = { overlay = true },
                    onRequestChanged = vm::onRequestChanged,
                )
            }
        }
        if (overlay && !menuVisible) {
            LiveOverlay(vm, onHide = { overlay = false; vm.setLiveOverlayOnEnter(false) }, pinText = pinText)
        }
    }
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun LiveOverlay(vm: AppViewModel, onHide: () -> Unit, pinText: String) {
    val snap by vm.live.collectAsStateWithLifecycle()
    val epg by vm.epg.collectAsStateWithLifecycle()
    val rev by vm.epgRevision.collectAsStateWithLifecycle()
    val current by vm.current.collectAsStateWithLifecycle()
    val shell = LocalShellFocus.current
    val scope = rememberCoroutineScope()

    var groupId by rememberSaveable { mutableStateOf(vm.lastLiveGroup ?: initialGroup(snap, current)) }
    if (snap.groups.none { it.id == groupId } && snap.groups.isNotEmpty()) groupId = GroupIds.ALL
    var query by rememberSaveable { mutableStateOf("") }
    // Suchliste erst beim ersten Suchen aufbauen (spart Zeit beim Öffnen der Liste).
    val engine = remember(snap) { lazy { SearchEngine(snap.channels, emptyMap()) } }
    val channels = remember(snap, groupId, query) {
        if (SearchEngine.normalize(query).length >= 2) engine.value.search(query, 0).channels else snap.channelsOf(groupId)
    }
    var focused by remember { mutableStateOf<Channel?>(null) }
    var menuFor by remember { mutableStateOf<Channel?>(null) }

    val listState = rememberLazyListState()
    val groupReq = remember { FocusRequester() }
    val listReq = remember { FocusRequester() }
    var overlayHasFocus by remember { mutableStateOf(false) }
    val searchReq = remember { FocusRequester() }
    val target = remember(channels) { channels.indexOfFirst { it.id == current?.id }.coerceAtLeast(0) }

    // Beim Öffnen: zur laufenden Sendung springen und fokussieren.
    LaunchedEffect(Unit) {
        if (channels.isNotEmpty()) listState.scrollToItem((target - 3).coerceAtLeast(0))
        if (!shell.content.requestSoon()) groupReq.requestSoon()
    }

    // Andere Gruppe → Liste von oben (erster Aufruf: zur laufenden Sendung, siehe oben).
    var firstGroup by remember { mutableStateOf(true) }
    LaunchedEffect(groupId, query) {
        if (firstGroup) firstGroup = false else listState.scrollToItem(0)
    }

    val play: (Channel) -> Unit = { c ->
        vm.lastLiveGroup = groupId
        vm.play(c, channels, pinText, openLive = false)
    }

    Box(
        Modifier.fillMaxSize()
            .onFocusChanged { st ->
                val had = overlayHasFocus
                overlayHasFocus = st.hasFocus
                // Der Player holt sich nach dem Umschalten den Fokus – die Liste bleibt
                // aber offen (OK schaltet hinter der Liste um) → Fokus zurückholen.
                if (had && !st.hasFocus && menuFor == null) scope.launch {
                    withFrameNanos { }
                    if (!listReq.requestSoon()) groupReq.requestSoon()
                }
            }
            .onKeyEvent { ev ->
            // Zurück: Liste ausblenden (Video läuft weiter).
            if (ev.nativeKeyEvent.keyCode == AndroidKeyEvent.KEYCODE_BACK) {
                if (ev.type == KeyEventType.KeyUp) onHide()
                true
            } else false
        },
    ) {
        Box(
            Modifier.fillMaxHeight().width(530.dp).background(
                Brush.horizontalGradient(0f to Color(0xF7070A0D), 0.8f to Color(0xF0070A0D), 1f to Color.Transparent),
            ),
        )
        // ---- Gruppen
        Column(Modifier.padding(start = 32.dp, top = 24.dp).width(130.dp)) {
            DpadTextField(
                query, { query = it }, stringResource(R.string.searchChannels), Modifier.fillMaxWidth(),
                leading = Icons.Rounded.Search, wrapperFocus = searchReq,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.groups).uppercase(), color = Color(0xFF8A90A0), fontFamily = Inter,
                fontWeight = FontWeight.Bold, fontSize = 7.5.sp, letterSpacing = 1.5.sp, modifier = Modifier.padding(bottom = 6.dp, start = 8.dp),
            )
            GroupColumn(snap.groups, groupId, groupReq, onSelect = { groupId = it; query = "" }, rightTo = listReq)
        }
        // ---- Sender
        Box(Modifier.padding(start = 172.dp, top = 24.dp, bottom = 40.dp).width(330.dp)) {
            if (channels.isEmpty()) {
                EmptyHint(stringResource(R.string.noChannels), stringResource(R.string.thereNothingGroup))
            }
            LazyColumn(state = listState, contentPadding = PaddingValues(vertical = 2.dp), modifier = Modifier.focusRequester(listReq).focusRestorer()) {
                itemsIndexed(channels, key = { _, c -> c.id }) { i, c ->
                    ChannelRow(
                        c = c, number = snap.numberOf(c, i), snap = snap, epg = epg, rev = rev,
                        modifier = Modifier
                            .then(if (i == target) Modifier.focusRequester(shell.content) else Modifier)
                            .focusProperties { left = groupReq }
                            .onFocusChanged { if (it.isFocused) focused = c }
                            .onPreviewKeyEvent { ev ->
                                if (ev.nativeKeyEvent.keyCode == AndroidKeyEvent.KEYCODE_DPAD_RIGHT && ev.type == KeyEventType.KeyDown) { play(c); true } else false
                            },
                        onClick = { play(c) },
                        onLong = { menuFor = c },
                        onWant = { vm.wantEpg(c) },
                    )
                }
            }
        }
        Text(
            stringResource(AppR.string.tv_liveHint), color = Color(0xFF7D8495), fontFamily = Inter, fontSize = 8.sp,
            modifier = Modifier.align(Alignment.BottomStart).padding(start = 32.dp, bottom = 18.dp),
        )
        NowPlayingCard(focused ?: current, epg, rev, Modifier.align(Alignment.BottomEnd).padding(end = 30.dp, bottom = 30.dp))
    }

    menuFor?.let { c ->
        ChannelOptions(vm, c, pinText = pinText, onDismiss = {
            menuFor = null
            scope.launch { shell.content.requestSoon() }
        })
    }
}

/** Startgruppe: Favoriten (wenn vorhanden), sonst Alle. */
private fun initialGroup(snap: LiveSnapshot, current: Channel?): String {
    val fav = snap.channelsOf(GroupIds.FAV)
    if (current != null && fav.any { it.id == current.id }) return GroupIds.FAV
    if (current != null) return GroupIds.ALL
    return if (fav.isNotEmpty()) GroupIds.FAV else GroupIds.ALL
}

@Composable
private fun GroupColumn(
    groups: List<GroupEntry>,
    selected: String,
    req: FocusRequester,
    onSelect: (String) -> Unit,
    rightTo: FocusRequester,
) {
    val accent = LocalAccent.current.color
    val state = rememberLazyListState(initialFirstVisibleItemIndex = groups.indexOfFirst { it.id == selected }.coerceAtLeast(0).let { (it - 4).coerceAtLeast(0) })
    LazyColumn(state = state, verticalArrangement = Arrangement.spacedBy(1.dp), modifier = Modifier.fillMaxHeight().padding(bottom = 40.dp)) {
        itemsIndexed(groups, key = { _, g -> g.id }) { _, g ->
            val sel = g.id == selected
            Row(
                Modifier.fillMaxWidth()
                    .then(if (sel) Modifier.focusRequester(req) else Modifier)
                    .focusProperties { right = rightTo }
                    .focusRing(accent, focusedBg = AppColors.rowFocus, bg = if (sel) AppColors.rowSelected else Color.Transparent, radius = 5.dp)
                    .onFocusChanged { if (it.isFocused && !sel) onSelect(g.id) }
                    .tvClick { onSelect(g.id) }
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    groupLabel(g), color = if (sel) Color.White else Color(0xFFB9BFCC), fontFamily = Inter,
                    fontWeight = if (sel) FontWeight.SemiBold else FontWeight.Normal, fontSize = 10.5.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                Text(fmtCount(g.count), color = if (sel) Color.White else Color(0xFFB9BFCC), fontFamily = Inter, fontSize = 10.5.sp, modifier = Modifier.padding(start = 6.dp))
            }
        }
    }
}

/** Zeile der Senderliste: Nummer, Logo, Name (+Stern/Schloss/Varianten), jetzt/bis, Fortschritt, Danach. */
@Composable
fun ChannelRow(
    c: Channel,
    number: Int,
    snap: LiveSnapshot,
    epg: EpgIndex,
    rev: Long,
    modifier: Modifier,
    onClick: () -> Unit,
    onLong: () -> Unit,
    onWant: () -> Unit,
) {
    val accent = LocalAccent.current.color
    val nowState = LocalNow.current
    val nn by remember(c, epg, rev) { derivedStateOf { epg.nowNext(c, nowState.value) } }
    LaunchedEffect(c.id, rev) { if (nn.isEmpty) onWant() }
    val variants = snap.variantCount(c)
    Row(
        modifier.fillMaxWidth().height(33.dp)
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 6.dp)
            .tvClick(onLongClick = onLong, onClick = onClick)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("$number", color = Color(0xFF7D8495), fontFamily = Inter, fontSize = 9.5.sp, textAlign = TextAlign.End, modifier = Modifier.width(17.dp))
        Spacer(Modifier.width(8.dp))
        ChannelLogo(c.name, c.logoUrl, height = 20.dp)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(c.name, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 10.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (snap.isFavorite(c)) { Spacer(Modifier.width(3.dp)); FavStar(size = 8.dp) }
                if (snap.isLocked(c)) { Spacer(Modifier.width(3.dp)); LockIcon(size = 8.dp) }
                if (variants > 1) { Spacer(Modifier.width(4.dp)); VariantBadge(variants) }
            }
            val now = nn.now
            Text(
                if (now != null) "${now.title} · ${stringResource(R.string.untilTime, hm(now.endMs))}" else stringResource(R.string.noProgrammeInfo),
                color = Color(0xFF9AA1B2), fontFamily = Inter, fontSize = 8.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (now != null) EpgProgress(now, Modifier.width(150.dp).padding(top = 2.dp), height = 2.dp)
        }
        Text(
            nn.next?.let { stringResource(R.string.upNextAt, it.title) } ?: "",
            color = Color(0xFF8A90A0), fontFamily = Inter, fontSize = 7.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.End, modifier = Modifier.width(75.dp).padding(start = 6.dp),
        )
    }
}

/** Karte unten rechts: „LÄUFT GERADE · Sender“, Titel, Zeit/Genre, Fortschritt. */
@Composable
private fun NowPlayingCard(c: Channel?, epg: EpgIndex, rev: Long, modifier: Modifier) {
    c ?: return
    val nowState = LocalNow.current
    val e by remember(c, epg, rev) { derivedStateOf { epg.nowNext(c, nowState.value).now } }
    Column(modifier.width(360.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xD1070A0D)).padding(horizontal = 13.dp, vertical = 11.dp)) {
        Kicker("${stringResource(R.string.onNowLower)} · ${c.name}")
        Text(
            e?.title ?: c.name, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 15.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 3.dp, bottom = 2.dp),
        )
        val ee = e
        if (ee != null) {
            Text(
                listOfNotNull("${hm(ee.startMs)} – ${hm(ee.endMs)}", ee.genre).joinToString(" · "),
                color = Color(0xFFAAB0BF), fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1,
            )
            EpgProgress(ee, Modifier.fillMaxWidth().padding(top = 6.dp), height = 2.dp)
        }
    }
}
