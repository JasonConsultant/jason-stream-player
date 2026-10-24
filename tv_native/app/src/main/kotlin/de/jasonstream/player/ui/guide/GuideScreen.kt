package de.jasonstream.player.ui.guide

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.ui.platform.testTag
import de.jasonstream.player.ui.common.dpadList
import de.jasonstream.player.ui.common.probe
import de.jasonstream.player.ui.common.rememberDpadList
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.focusable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.player.R as AppR
import de.jasonstream.player.logic.EpgIndex
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.GuideCell
import de.jasonstream.player.logic.GuideCursor
import de.jasonstream.player.logic.GuideDays
import de.jasonstream.player.logic.GuideNav
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.LocalShellFocus
import de.jasonstream.player.ui.PlayerHost
import de.jasonstream.player.ui.common.ChannelLogo
import de.jasonstream.player.ui.common.EmptyHint
import de.jasonstream.player.ui.common.EpgProgress
import de.jasonstream.player.ui.common.Kicker
import de.jasonstream.player.ui.common.LocalNow
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.hm
import de.jasonstream.player.ui.common.isOkKey
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.live.ChannelOptions
import de.jasonstream.player.ui.live.groupLabel
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Maßstab: 30 Minuten = 180 dp (Entwurf a2: 360 px). */
private val DP_PER_MIN = 6.dp
private val ROW_H = 36.dp
private val ROW_GAP = 3.dp
private val CH_COL = 130.dp

@Composable
private fun dayLabel(offset: Int, now: Long): String = when (offset) {
    -1 -> stringResource(R.string.yesterday)
    0 -> stringResource(R.string.today)
    1 -> stringResource(R.string.tomorrow)
    else -> remember(offset, now / 86_400_000) {
        SimpleDateFormat("EEE dd.MM.", Locale.getDefault()).format(Date(GuideDays.jumpTarget(offset, now)))
    }
}

/**
 * TV-Guide (Entwurf a2): Mini-Video oben links, Info zur fokussierten
 * Sendung, darunter das Raster. Das Raster ist **ein** Fokusziel mit
 * eigener Tastensteuerung – Zeilen (LazyColumn) und Zellen (nur das
 * sichtbare Zeitfenster) werden virtualisiert, auch bei 2 000+ Sendern.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun GuideScreen(vm: AppViewModel, player: PlayerHost) {
    probe("GuideScreen")
    val snap by vm.live.collectAsStateWithLifecycle()
    val epg by vm.epg.collectAsStateWithLifecycle()
    val rev by vm.epgRevision.collectAsStateWithLifecycle()
    val current by vm.current.collectAsStateWithLifecycle()
    val portal by vm.portal.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val shell = LocalShellFocus.current
    val nowState = LocalNow.current
    val accent = LocalAccent.current.color
    val pinText = stringResource(R.string.enterPin)
    val remindText = stringResource(R.string.reminderActive)
    val notArchived = stringResource(R.string.programmeNotArchive)

    var groupId by rememberSaveable { mutableStateOf(vm.lastGuideGroup ?: GroupIds.ALL) }
    if (snap.groups.isNotEmpty() && snap.groups.none { it.id == groupId }) groupId = GroupIds.ALL
    val channels = remember(snap, groupId) { snap.channelsOf(groupId) }

    val now0 = remember { nowState.value }
    val minT = remember(now0) { EpgWindow.from(now0) }
    val maxT = remember(now0) { EpgWindow.to(now0) }
    var cursor by remember {
        val row = channels.indexOfFirst { it.id == current?.id }.coerceAtLeast(0)
        mutableStateOf(GuideCursor(row, now0, GuideNav.floorSlot(now0) - GuideNav.SLOT))
    }
    if (cursor.row > channels.lastIndex && channels.isNotEmpty()) cursor = cursor.copy(row = channels.lastIndex)
    var gridFocused by remember { mutableStateOf(false) }
    var spanMs by remember { mutableLongStateOf(120L * 60_000) }
    var menuFor by remember { mutableStateOf<Channel?>(null) }
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = (cursor.row - 2).coerceAtLeast(0))

    val focusedChannel = channels.getOrNull(cursor.row)
    val focusedCell: GuideCell? = remember(focusedChannel, epg, rev, cursor.anchor) {
        focusedChannel?.let { GuideNav.cellAt(epg, epg.of(it), cursor.anchor) }
    }

    // Gewählte Zeile sichtbar halten (ohne Animation – flüssig auch beim Halten der Taste).
    LaunchedEffect(cursor.row) {
        val info = listState.layoutInfo
        val visible = info.visibleItemsInfo
        if (visible.isEmpty()) { listState.scrollToItem((cursor.row - 2).coerceAtLeast(0)); return@LaunchedEffect }
        val full = visible.filter { it.offset >= 0 && it.offset + it.size <= info.viewportEndOffset }
        val first = full.firstOrNull()?.index ?: visible.first().index
        val last = full.lastOrNull()?.index ?: visible.last().index
        if (cursor.row < first) listState.scrollToItem(cursor.row)
        else if (cursor.row > last) listState.scrollToItem((cursor.row - (last - first)).coerceAtLeast(0))
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 32.dp)) {
        // ---- Kopf: Mini-Video + Info
        Row(Modifier.fillMaxWidth().padding(top = 10.dp).height(112.dp)) {
            player.Mini(current, portal?.id, Modifier.size(199.dp, 112.dp).clip(RoundedCornerShape(7.dp)))
            Spacer(Modifier.width(16.dp))
            GuideInfo(focusedChannel, focusedCell, Modifier.weight(1f))
        }
        // ---- Tage + Gruppen
        val offsets = remember(epg, now0) { GuideDays.offsets(epg.span(), now0) }
        val selDay = GuideDays.dayOf(cursor.anchor, now0)
        // Tage + Gruppen: ◀▶ selbst geführt (Slots ohne Trenner), an beiden Enden Schluss.
        val nDays = offsets.size
        val chipsNav = rememberDpadList(rememberLazyListState(), nDays + snap.groups.size, vertical = false)
        chipsNav.lazyIndexOf = { sl -> if (sl < nDays) sl else sl + 1 }
        LazyRow(
            Modifier.fillMaxWidth().padding(top = 9.dp).testTag("guide_chips").focusRestorer().focusProperties { up = shell.menu }.dpadList(chipsNav),
            state = chipsNav.lazy!!,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            itemsIndexed(offsets, key = { _, d -> "d$d" }) { i, d ->
                Chip(dayLabel(d, now0), d == selDay, chipsNav.item(i)) {
                    cursor = GuideNav.jump(cursor, if (d == 0) nowState.value else GuideDays.jumpTarget(d, now0), spanMs, minT, maxT)
                }
            }
            item(key = "sep") { Box(Modifier.padding(horizontal = 4.dp).size(1.dp, 18.dp).background(AppColors.line)) }
            itemsIndexed(snap.groups, key = { _, g -> "g" + g.id }) { i, g ->
                Chip(groupLabel(g), g.id == groupId, chipsNav.item(nDays + i)) {
                    groupId = g.id
                    vm.lastGuideGroup = g.id
                    cursor = cursor.copy(row = 0)
                }
            }
        }
        // ---- Raster
        BoxWithConstraints(Modifier.fillMaxWidth().weight(1f).padding(top = 8.dp, bottom = 12.dp)) {
            val gridW = maxWidth - CH_COL
            val span = (gridW / DP_PER_MIN).toLong() * 60_000L
            SideEffect { spanMs = span }
            val pxPerMs = with(androidx.compose.ui.platform.LocalDensity.current) { DP_PER_MIN.toPx() / 60_000f }
            if (channels.isEmpty()) {
                EmptyHint(
                    if (status.loadingList) stringResource(R.string.loadingSavedData) else stringResource(R.string.noChannels),
                    modifier = Modifier.focusRequester(shell.content).focusable(),
                )
                return@BoxWithConstraints
            }
            Column(
                Modifier.fillMaxSize()
                    .focusRequester(shell.content)
                    // Fokusfalle: ▼◀▶ verlassen das Raster nie (▲ geht zu den Filtern).
                    .focusProperties {
                        onExit = {
                            val d = requestedFocusDirection
                            if (d == FocusDirection.Down || d == FocusDirection.Left || d == FocusDirection.Right) cancelFocusChange()
                        }
                    }
                    .onFocusChanged { gridFocused = it.isFocused }
                    .onKeyEvent { ev ->
                        val code = ev.nativeKeyEvent.keyCode
                        val down = ev.type == KeyEventType.KeyDown
                        val ch = focusedChannel
                        when {
                            code == AndroidKeyEvent.KEYCODE_DPAD_UP -> {
                                if (cursor.row == 0) return@onKeyEvent false // weiter nach oben zu den Chips
                                if (down) cursor = GuideNav.vertical(cursor, -1, channels.size)
                                true
                            }
                            code == AndroidKeyEvent.KEYCODE_DPAD_DOWN -> {
                                if (down) cursor = GuideNav.vertical(cursor, 1, channels.size); true
                            }
                            code == AndroidKeyEvent.KEYCODE_PAGE_UP || code == AndroidKeyEvent.KEYCODE_CHANNEL_UP -> {
                                if (down) cursor = GuideNav.vertical(cursor, -7, channels.size); true
                            }
                            code == AndroidKeyEvent.KEYCODE_PAGE_DOWN || code == AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> {
                                if (down) cursor = GuideNav.vertical(cursor, 7, channels.size); true
                            }
                            code == AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> {
                                if (down && ch != null) cursor = GuideNav.right(epg, epg.of(ch), cursor, span, minT, maxT); true
                            }
                            code == AndroidKeyEvent.KEYCODE_DPAD_LEFT -> {
                                if (down && ch != null) cursor = GuideNav.left(epg, epg.of(ch), cursor, span, minT, maxT); true
                            }
                            code == AndroidKeyEvent.KEYCODE_MENU -> {
                                if (!down && ch != null) menuFor = ch; true
                            }
                            isOkKey(code) -> {
                                if (down && ev.nativeKeyEvent.repeatCount == 1 && ch != null) menuFor = ch // lange OK
                                if (!down && ev.nativeKeyEvent.isCanceled.not() && ch != null && menuFor == null && focusedCell != null) {
                                    when (GuideNav.actionFor(focusedCell, nowState.value, ch.catchupDays)) {
                                        GuideNav.Action.PlayLive -> vm.play(ch, channels, pinText)
                                        GuideNav.Action.PlayCatchup -> focusedCell.entry?.let { vm.playCatchup(ch, it, pinText) }
                                        GuideNav.Action.Remind -> vm.remind(ch, focusedCell.entry, remindText)
                                        GuideNav.Action.None -> vm.toast(notArchived)
                                    }
                                }
                                true
                            }
                            else -> false
                        }
                    }
                    .focusable(),
            ) {
                TimeHeader(cursor.viewStart, span)
                Box(Modifier.fillMaxSize()) {
                    LazyColumn(state = listState, userScrollEnabled = false, verticalArrangement = Arrangement.spacedBy(ROW_GAP)) {
                        itemsIndexed(channels, key = { _, c -> c.id }) { i, c ->
                            GuideRow(
                                c, epg, rev, cursor.viewStart, span,
                                selected = if (i == cursor.row && gridFocused) focusedCell else null,
                                accent = accent,
                                onWant = { vm.wantEpg(c) },
                            )
                        }
                    }
                    // Jetzt-Linie (nur Zeichenphase).
                    val viewStart = cursor.viewStart
                    Canvas(Modifier.fillMaxHeight().fillMaxWidth()) {
                        val x = CH_COL.toPx() + (nowState.value - viewStart) * pxPerMs
                        if (x >= CH_COL.toPx() && x <= size.width) {
                            drawLine(AppColors.nowLine, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1.dp.toPx())
                        }
                    }
                }
            }
        }
    }

    menuFor?.let { c -> ChannelOptions(vm, c, pinText) { menuFor = null } }
}

@Composable
private fun Chip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val accent = LocalAccent.current.color
    Box(
        modifier.clip(RoundedCornerShape(10.dp))
            .focusRing(Color.White, focusedBg = if (selected) accent else AppColors.surface3, bg = if (selected) accent else AppColors.surface2, radius = 10.dp, width = 1.5.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(label, color = if (selected) AppColors.onAccent else AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 8.5.sp, maxLines = 1)
    }
}

@Composable
private fun TimeHeader(viewStart: Long, span: Long) {
    Box(Modifier.fillMaxWidth().height(17.dp).padding(start = CH_COL).clipToBounds()) {
        var t = GuideNav.floorSlot(viewStart)
        while (t < viewStart + span) {
            if (t >= viewStart) {
                val x = DP_PER_MIN * ((t - viewStart) / 60_000f)
                Text(hm(t), color = Color(0xFF8A90A0), fontFamily = Inter, fontSize = 8.sp, modifier = Modifier.offset(x = x))
            }
            t += GuideNav.SLOT
        }
    }
}

/** Eine Zeile: Sender links, Sendungen des sichtbaren Fensters rechts. */
@Composable
private fun GuideRow(
    c: Channel,
    epg: EpgIndex,
    rev: Long,
    viewStart: Long,
    span: Long,
    selected: GuideCell?,
    accent: Color,
    onWant: () -> Unit,
) {
    probe("GuideRow")
    val list = remember(c, epg, rev) { epg.of(c) }
    LaunchedEffect(c.id, rev) { if (list.isEmpty()) onWant() }
    val visible = remember(list, viewStart, span) { epg.range(list, viewStart, viewStart + span) }
    val nowState = LocalNow.current
    Row(Modifier.fillMaxWidth().height(ROW_H)) {
        Row(Modifier.width(CH_COL - 4.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
            ChannelLogo(c.name, c.logoUrl, height = 18.dp)
            Spacer(Modifier.width(6.dp))
            Text(c.name, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 9.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(4.dp))
        Box(Modifier.weight(1f).fillMaxHeight().clipToBounds()) {
            if (visible.isEmpty() && selected == null) {
                Cell(stringResource(R.string.noProgrammeInfo), null, 0.dp, DP_PER_MIN * (span / 60_000f), false, false, accent)
            }
            for (e in visible) {
                key(e.startMs) {
                    val x = DP_PER_MIN * ((e.startMs - viewStart) / 60_000f)
                    val w = DP_PER_MIN * ((e.endMs - e.startMs) / 60_000f)
                    val isSel = selected?.entry === e || (selected?.entry != null && selected.entry.startMs == e.startMs)
                    val isNow = e.isNowAt(nowState.value)
                    Cell(e.title, timeText(e), x, w, isNow, isSel, accent)
                }
            }
            if (selected != null && selected.entry == null) {
                val x = DP_PER_MIN * ((selected.start - viewStart) / 60_000f)
                val w = DP_PER_MIN * ((selected.end - selected.start) / 60_000f)
                Cell(stringResource(R.string.noProgrammeInfo), null, x, w, false, true, accent)
            }
        }
    }
}

private fun timeText(e: EpgEntry) = "${hm(e.startMs)} – ${hm(e.endMs)}"

@Composable
private fun Cell(title: String, sub: String?, x: Dp, w: Dp, now: Boolean, selected: Boolean, accent: Color) {
    // Zelle beginnt links vom Fenster → Text am Fensterrand beginnen lassen.
    val start = if (x < 0.dp) 0.dp else x
    val width = (w - (start - x) - 3.dp).coerceAtLeast(2.dp)
    val bg = when {
        selected -> accent
        now -> AppColors.cellNow
        else -> AppColors.cell
    }
    Column(
        Modifier.offset(x = start).width(width).fillMaxHeight().clip(RoundedCornerShape(5.dp)).background(bg)
            .padding(horizontal = 7.dp, vertical = 5.dp),
    ) {
        Text(title, color = if (selected) Color(0xFF140A04) else AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (sub != null) Text(sub, color = if (selected) Color(0xFF3A1D0C) else Color(0xFF8A90A0), fontFamily = Inter, fontSize = 7.sp, maxLines = 1)
    }
}

/** Info oben: „SENDER · JETZT“, Titel, Zeit · Genre · Beschreibung, Fortschritt. */
@Composable
private fun GuideInfo(c: Channel?, cell: GuideCell?, modifier: Modifier) {
    val nowState = LocalNow.current
    Column(modifier.padding(top = 4.dp).testTag("guide_info")) {
        if (c == null) return@Column
        val e = cell?.entry
        val now = nowState.value
        val whenText = when {
            e == null -> stringResource(R.string.noProgrammeInfo)
            e.isNowAt(now) -> stringResource(R.string.nowUpper)
            else -> {
                val d = GuideDays.dayOf(e.startMs, now)
                val day = when (d) {
                    0 -> stringResource(R.string.todayLower)
                    -1 -> stringResource(R.string.yesterdayLower)
                    1 -> stringResource(R.string.tomorrowLower)
                    else -> SimpleDateFormat("EEE dd.MM.", Locale.getDefault()).format(Date(e.startMs))
                }
                "$day ${hm(e.startMs)}"
            }
        }
        Kicker("${c.name} · $whenText")
        Text(
            e?.title ?: c.name, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 19.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 5.dp, bottom = 3.dp),
        )
        if (e != null) {
            Text(
                listOfNotNull(timeText(e), e.genre).joinToString(" · ") + (e.description?.let { "  ·  $it" } ?: ""),
                color = Color(0xFFAAB0BF), fontFamily = Inter, fontSize = 9.sp, lineHeight = 13.sp, maxLines = 3,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 450.dp),
            )
            if (e.isNowAt(now)) EpgProgress(e, Modifier.width(260.dp).padding(top = 8.dp), height = 2.dp)
        }
        Text(stringResource(AppR.string.tv_guideHint), color = AppColors.textFaint, fontFamily = Inter, fontSize = 7.sp, modifier = Modifier.padding(top = 6.dp))
    }
}
