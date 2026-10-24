package de.jasonstream.player.ui.settings

import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.SoakController
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.PlayerHost
import de.jasonstream.player.ui.common.dpadList
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.focusTrap
import de.jasonstream.player.ui.common.rememberDpadList
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type
import de.jasonstream.playback.soak.SoakAbort
import de.jasonstream.playback.soak.SoakMachine
import de.jasonstream.playback.stats.Grade
import de.jasonstream.playback.stats.Metric
import de.jasonstream.playback.stats.PlaybackStats
import de.jasonstream.playback.stats.StatsData
import de.jasonstream.playback.stats.Targets
import java.text.DateFormat
import java.util.Date

/** Ampelfarben. */
private fun gradeColor(g: Grade) = when (g) {
    Grade.green -> Color(0xFF43C06A)
    Grade.yellow -> Color(0xFFE8B931)
    Grade.red -> Color(0xFFE5484D)
    Grade.none -> Color(0xFF4A5062)
}

private fun fmtDuration(ms: Long): String {
    val m = ms / 60_000
    return if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min"
}

/** Zeile der Seite (alles per ▲▼ erreichbar). */
private sealed interface StatRow {
    data object Title : StatRow
    data class MetricRow(val m: Metric) : StatRow
    data object Zaps : StatRow
    data object Reset : StatRow
    data object SoakHeader : StatRow
    data class Soak(val count: Int) : StatRow
}

/**
 * Einstellungen → Wiedergabe-Statistik. Ampel nach Zielwerten, Zähler,
 * „Zurücksetzen“. Versteckt: 3× OK auf die Überschrift schaltet den Dauertest
 * frei (20/100/300 Senderwechsel durch die aktuelle Liste).
 */
@Composable
fun StatsScreen(vm: AppViewModel, player: PlayerHost) {
    val rec = PlaybackStats.session
    val rev = rec.revision
    val data = remember(rev) { rec.data }
    val accent = LocalAccent.current.color
    val scope = rememberCoroutineScope()
    val request by vm.request.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()
    val portal by vm.portal.collectAsStateWithLifecycle()

    var soakUnlocked by remember { mutableStateOf(false) }
    var titleTaps by remember { mutableIntStateOf(0) }
    var soak by remember { mutableStateOf<SoakController?>(null) }
    val unlockedText = stringResource(R.string.soakUnlocked)
    val resetText = stringResource(R.string.statResetDone)
    val noChannels = stringResource(R.string.soakNoChannels)

    // Dauertest: Zurück bricht ab; Hintergrund bricht ab.
    val running = soak?.running == true
    BackHandler(enabled = running) { soak?.cancel() }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_STOP) soak?.cancel(SoakAbort.background) }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs); soak?.dispose() }
    }

    fun startSoak(count: Int) {
        val eng = player.engine
        val deps = player.deps
        val pid = portal?.id
        val list = request?.channels?.takeIf { it.isNotEmpty() } ?: live.channelsOf(GroupIds.ALL)
        if (eng == null || deps == null || pid == null || list.isEmpty()) { vm.toast(noChannels); return }
        val startAt = request?.index?.coerceIn(0, list.size - 1) ?: 0
        val c = SoakController(eng, deps, scope, pid, list, startAt)
        if (c.channels.isEmpty()) { vm.toast(noChannels); return }
        soak = c
        c.start(count)
    }

    val rows: List<StatRow> = buildList {
        add(StatRow.Title)
        Metric.entries.forEach { add(StatRow.MetricRow(it)) }
        add(StatRow.Zaps)
        add(StatRow.Reset)
        if (soakUnlocked) {
            add(StatRow.SoakHeader)
            SoakMachine.COUNT_OPTIONS.forEach { add(StatRow.Soak(it)) }
        }
    }
    val focusable = rows.indices.filter { rows[it] !is StatRow.SoakHeader }
    val slotOf = IntArray(rows.size) { -1 }.also { a -> focusable.forEachIndexed { s, li -> a[li] = s } }
    val listState = rememberLazyListState()
    val nav = rememberDpadList(listState, focusable.size)
    nav.lazyIndexOf = { focusable.getOrElse(it) { 0 } }
    LaunchedEffect(Unit) { nav.index = 0; nav.requester(0).requestSoon() }
    // Dauertest freigeschaltet → auf den ersten Dauertest-Eintrag.
    LaunchedEffect(soakUnlocked) { if (soakUnlocked) nav.focus(focusable.size - SoakMachine.COUNT_OPTIONS.size) }

    Box(Modifier.fillMaxSize().background(AppColors.bg)) {
        val s = soak
        if (s != null && (s.running || s.result != null)) {
            SoakView(s, player, accent, onClose = { soak = null })
            return@Box
        }
        LazyColumn(
            Modifier.fillMaxSize().padding(horizontal = 32.dp).testTag("stats_list").focusTrap().dpadList(nav),
            state = listState,
            contentPadding = PaddingValues(top = 22.dp, bottom = 30.dp),
        ) {
            itemsIndexed(rows) { li, r ->
                val m = if (slotOf[li] >= 0) nav.item(slotOf[li]) else Modifier
                when (r) {
                    StatRow.Title -> TitleRow(data, accent, m.testTag("stats_title")) {
                        titleTaps++
                        if (titleTaps >= 3 && !soakUnlocked) { soakUnlocked = true; vm.toast(unlockedText) }
                    }
                    is StatRow.MetricRow -> MetricLine(r.m, data, accent, m)
                    StatRow.Zaps -> ZapsRow(data, accent, m)
                    StatRow.Reset -> ActionLine(Icons.Rounded.RestartAlt, stringResource(R.string.statReset), null, accent, m.testTag("stats_reset")) {
                        rec.reset(); titleTaps = 0; vm.toast(resetText)
                    }
                    StatRow.SoakHeader -> Column(Modifier.padding(top = 14.dp, bottom = 4.dp, start = 10.dp)) {
                        Text(stringResource(R.string.soakTitle).uppercase(), color = AppColors.textFaint, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 7.5.sp, letterSpacing = 1.5.sp)
                        Text(stringResource(R.string.soakHint), color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 2)
                    }
                    is StatRow.Soak -> ActionLine(Icons.Rounded.PlayArrow, stringResource(R.string.soakStartN, "${r.count}"), null, accent, m.testTag("soak_${r.count}")) {
                        startSoak(r.count)
                    }
                }
            }
        }
    }
}

@Composable
private fun TitleRow(data: StatsData, accent: Color, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.playStats), style = Type.title)
            val since = data.since.takeIf { it > 0 }?.let { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it)) }
            Text(
                listOfNotNull(since?.let { stringResource(R.string.statSince, it) }, data.lastSoak.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.statLastSoak, it) })
                    .joinToString(" · ").ifEmpty { stringResource(R.string.playStatsHint) },
                color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(10.dp))
        Text(stringResource(R.string.statOverall), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp)
        Spacer(Modifier.width(6.dp))
        Lamp(data.overall, 16.dp)
    }
}

@Composable
private fun Lamp(g: Grade, size: androidx.compose.ui.unit.Dp) {
    Box(Modifier.size(size).clip(CircleShape).background(gradeColor(g)))
}

@Composable
private fun MetricLine(m: Metric, d: StatsData, accent: Color, modifier: Modifier) {
    val title = when (m) {
        Metric.focus -> stringResource(R.string.statFocusReaction)
        Metric.appStart -> stringResource(R.string.statAppStart)
        Metric.zap -> stringResource(R.string.statZapTime)
        Metric.crashes -> stringResource(R.string.statCrashes)
        Metric.stalls -> stringResource(R.string.statStalls)
        Metric.focusLoss -> stringResource(R.string.statFocusLoss)
    }
    val target = when (m) {
        Metric.focus -> stringResource(R.string.statTargetMsP, "${Targets.FOCUS_P95_MS}", "P95")
        Metric.appStart -> stringResource(R.string.statTargetS, "${Targets.APP_START_MS / 1000}")
        Metric.zap -> stringResource(R.string.statTargetMsP, "${Targets.ZAP_P90_MS}", "P90")
        Metric.crashes, Metric.focusLoss -> stringResource(R.string.statTargetZero)
        Metric.stalls -> stringResource(R.string.statTargetStalls)
    }
    val none = stringResource(R.string.statNoData)
    val value = when (m) {
        Metric.focus -> d.focusP95?.let { stringResource(R.string.statFocusDetail, "${d.focusP50 ?: 0}", "$it", "${d.focusMs.size}") } ?: none
        Metric.appStart -> d.lastAppStartMs?.let { stringResource(R.string.statAppStartDetail, "$it", "${d.appStartWorstMs ?: it}") } ?: none
        Metric.zap -> d.zapP90?.let { stringResource(R.string.statP50P90, "${d.zapP50 ?: 0}", "$it") } ?: none
        Metric.crashes -> "${d.crashes}"
        Metric.stalls -> stringResource(R.string.statStallsDetail, "${d.stalls}", fmtDuration(d.watchMs))
        Metric.focusLoss -> "${d.focusLosses}"
    }
    Row(
        modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick { }
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Lamp(d.grade(m), 11.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp, maxLines = 1)
            Text(value, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(target, color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1)
    }
}

@Composable
private fun ZapsRow(d: StatsData, accent: Color, modifier: Modifier) {
    Column(
        modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick { }
            .padding(horizontal = 10.dp, vertical = 7.dp),
    ) {
        Text(
            stringResource(R.string.statZapsN, "${d.zapCount}", "${d.zapFailed}") + " · " + stringResource(R.string.statReconnects) + " ${d.reconnects}",
            color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp, maxLines = 1,
        )
        val last = d.zapLast20
        Text(
            stringResource(R.string.statLast20) + ": " + (if (last.isEmpty()) stringResource(R.string.statNoData) else last.joinToString(" ")),
            color = AppColors.textDim, fontFamily = FontFamily.Monospace, fontSize = 8.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ActionLine(icon: ImageVector, title: String, value: String?, accent: Color, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = AppColors.textDim, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp, maxLines = 1)
            if (value != null) Text(value, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 2)
        }
    }
}

/** Laufender/fertiger Dauertest: Video im Hintergrund, Fortschrittskarte, Ergebnis. */
@Composable
private fun SoakView(s: SoakController, player: PlayerHost, accent: Color, onClose: () -> Unit) {
    val eng = player.engine
    val okFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    Box(Modifier.fillMaxSize().background(Color.Black).testTag("soak_view")) {
        if (eng != null && s.running) {
            AndroidView(factory = { ctx -> SurfaceView(ctx).also { eng.attachSurface(it) } }, modifier = Modifier.fillMaxSize())
            DisposableEffect(eng) { onDispose { eng.attachSurface(null) } }
        }
        val r = s.result
        Column(
            Modifier.align(Alignment.BottomStart).padding(32.dp).widthIn(max = 460.dp)
                .clip(RoundedCornerShape(10.dp)).background(Color(0xE0070A0D)).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (r == null) {
                val m = s.machine
                Text(stringResource(R.string.soakRunning, "${s.step}", "${m?.count ?: 0}"), style = Type.rowTitle, color = AppColors.text)
                Text(s.currentChannel?.name ?: "", color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(stringResource(R.string.soakProgressDetail, "${s.ok}", "${s.failed}", "${s.lastMs ?: 0}"), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp)
                de.jasonstream.player.ui.common.ThinProgress((s.step.toFloat() / (m?.count ?: 1).coerceAtLeast(1)).coerceIn(0f, 1f), Modifier.fillMaxWidth().padding(top = 4.dp), height = 3.dp, color = accent)
                Text(stringResource(R.string.soakCancelHint), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp)
            } else {
                LaunchedEffect(Unit) { okFocus.requestSoon() }
                Text(stringResource(if (r.abort == SoakAbort.none) R.string.soakDone else R.string.soakAborted), style = Type.rowTitle, color = AppColors.text)
                Text(stringResource(R.string.soakResult, "${r.zaps}", "${r.planned}", "${r.ok}", "${r.failed}"), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp)
                Text(stringResource(R.string.soakResultTimes, "${r.p50Ms}", "${r.p90Ms}", "${r.maxMs}"), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp)
                if (r.abortDetail.isNotEmpty()) Text(r.abortDetail, color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp, maxLines = 2)
                Spacer(Modifier.height(6.dp))
                Box(
                    Modifier.focusRequester(okFocus).focusRing(accent, focusedBg = AppColors.rowFocus, bg = AppColors.surface3, radius = 8.dp)
                        .tvClick(onClick = onClose).padding(horizontal = 14.dp, vertical = 6.dp).testTag("soak_ok"),
                ) { Text("OK", color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 10.sp) }
            }
        }
        if (r != null) BackHandler { onClose() }
    }
}
