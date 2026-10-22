package de.jasonstream.playback.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import de.jasonstream.core.R as CR
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.playback.R
import de.jasonstream.playback.logic.StreamError
import de.jasonstream.playback.logic.StreamErrorKind
import de.jasonstream.playback.logic.fmtBehind
import de.jasonstream.playback.logic.fmtClock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val hmFormat = ThreadLocal.withInitial { SimpleDateFormat("HH:mm", Locale.ROOT) }
internal fun hm(ms: Long): String = hmFormat.get()!!.format(Date(ms))

// ---------------------------------------------------------------------------
// Zapping-Leiste (zap_bar.dart)
// ---------------------------------------------------------------------------
@Composable
internal fun ZapBar(c: PlayerController, ch: Channel, accent: Color) {
    val now = c.nowOf(ch)
    val next = c.nextOf(ch, now)
    val preview = c.barPreview
    val fav = c.isFavorite(ch)
    val dim = interStyle(15.sp, color = C.white70)
    Box(Modifier.fillMaxSize().padding(start = 56.dp, end = 56.dp, bottom = 32.dp), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier
                .widthIn(max = 980.dp)
                .fillMaxWidth()
                .background(C.bg.copy(alpha = 0.9f), RoundedCornerShape(16.dp))
                .border(if (preview) 2.dp else 1.dp, if (preview) accent else C.line, RoundedCornerShape(16.dp))
                .padding(horizontal = 18.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.chevronLeft, null, tint = C.white38, modifier = Modifier.size(22.dp))
            Text(
                "${ch.number}", Modifier.width(52.dp), textAlign = TextAlign.Center,
                style = interStyle(24.sp, FontWeight.ExtraBold, family = PlayerType.InterDisplay),
            )
            Spacer(Modifier.width(10.dp))
            ChannelLogo(ch.name, ch.logoUrl, 44.dp)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(ch.name, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = interStyle(15.sp, FontWeight.Bold, C.white70))
                    if (fav) {
                        Spacer(Modifier.width(6.dp))
                        Icon(Icons.star, null, tint = C.gold, modifier = Modifier.size(16.dp))
                    }
                    if (preview) {
                        Spacer(Modifier.width(10.dp))
                        Text(c.str(CR.string.previewOkSwitches), style = interStyle(13.sp, FontWeight.Bold, accent))
                    }
                }
                Spacer(Modifier.height(2.dp))
                Text(now?.title ?: c.str(CR.string.noProgrammeInfo), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = interStyle(18.sp, FontWeight.Bold))
                if (now != null) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${hm(now.startMs)} – ${hm(now.endMs)}", style = dim)
                        Spacer(Modifier.width(12.dp))
                        ThinProgress(now.progressAt(c.clock), accent, 4.dp, Modifier.weight(1f))
                    }
                }
                if (next != null) {
                    Spacer(Modifier.height(4.dp))
                    Text(c.str(CR.string.upNextAt, "${hm(next.startMs)} ${next.title}"), maxLines = 1,
                        overflow = TextOverflow.Ellipsis, style = interStyle(15.sp, color = C.white60))
                }
            }
            Icon(Icons.chevronRight, null, tint = C.white38, modifier = Modifier.size(22.dp))
        }
    }
}

// ---------------------------------------------------------------------------
// Live-Bedienelemente (_LiveOverlay + _TopBar)
// ---------------------------------------------------------------------------
@Composable
internal fun LiveOverlay(c: PlayerController, ch: Channel, accent: Color) {
    val now = c.nowOf(ch)
    val next = c.nextOf(ch, now)
    val shifted = c.shifted()
    val canRestart = ch.hasCatchup && now != null
    Column(Modifier.fillMaxSize()) {
        TopBar(c, accent) {
            Tag(c.str(CR.string.live), C.live, filled = true)
            Spacer(Modifier.width(10.dp))
            Text(ch.name, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = interStyle(16.sp, FontWeight.SemiBold))
            c.variantLabel?.let {
                Spacer(Modifier.width(8.dp))
                Tag(it, C.white70)
            }
            Spacer(Modifier.weight(1f))
            Text(hm(c.clock), style = interStyle(16.sp, FontWeight.SemiBold, C.white70))
            Spacer(Modifier.width(16.dp))
            if (c.hasVariants) {
                RoundBtn(Icons.layers, accent, { c.sheet = Sheet.variants }); Spacer(Modifier.width(8.dp))
            }
            if (canRestart) {
                PillBtn(Icons.replay, c.str(CR.string.fromStart), C.catchup, accent, c::restartShow); Spacer(Modifier.width(8.dp))
            }
            if (c.prevChannelId != null) {
                RoundBtn(Icons.swap, accent, c::zapBack); Spacer(Modifier.width(8.dp))
            }
            RoundBtn(if (c.isFavorite(ch)) Icons.star else Icons.starBorder, accent, { c.toggleFavorite(ch) }); Spacer(Modifier.width(8.dp))
            RoundBtn(Icons.record, accent, { c.record(ch) }); Spacer(Modifier.width(8.dp))
            RoundBtn(Icons.list, accent, c.onOpenChannelList, focusRequester = c.mainFocus); Spacer(Modifier.width(8.dp))
        }
        Spacer(Modifier.weight(1f))
        Row(
            Modifier.fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color(0x00000000), Color(0xEE000000))))
                .padding(start = 32.dp, end = 32.dp, top = 60.dp, bottom = 28.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                RoundBtn(Icons.up, accent, { c.zapTo(c.index + 1) }, size = 40.dp)
                Spacer(Modifier.height(8.dp))
                Text("${ch.number}", style = interStyle(30.sp, FontWeight.ExtraBold, family = PlayerType.InterDisplay))
                Spacer(Modifier.height(8.dp))
                RoundBtn(Icons.down, accent, { c.zapTo(c.index - 1) }, size = 40.dp)
            }
            if (c.timeshiftEnabled) {
                Spacer(Modifier.width(18.dp))
                Box(Modifier.padding(bottom = 34.dp)) {
                    RoundBtn(if (c.userPaused) Icons.play else Icons.pause, accent, c::togglePause, size = 52.dp)
                }
            }
            Spacer(Modifier.width(22.dp))
            ChannelLogo(ch.name, ch.logoUrl, 56.dp)
            Spacer(Modifier.width(22.dp))
            Column(Modifier.weight(1f)) {
                if (shifted) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(c.str(CR.string.timeshifted, fmtBehind(c.behindMs())), style = interStyle(14.sp, FontWeight.Medium, C.gold))
                        Spacer(Modifier.width(14.dp))
                        PillBtn(Icons.circle, c.str(CR.string.backToLive), C.live, accent, c::goLiveEdge, filled = true)
                    }
                    Spacer(Modifier.height(8.dp))
                }
                if (now != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(c.str(CR.string.nowUpper), style = interStyle(11.sp, FontWeight.SemiBold, accent).copy(letterSpacing = 0.6.sp))
                        Spacer(Modifier.width(10.dp))
                        Text("${hm(now.startMs)} – ${hm(now.endMs)}", style = interStyle(12.sp, color = C.white70))
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(now.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = interStyle(24.sp, FontWeight.Bold, family = PlayerType.InterDisplay).copy(letterSpacing = (-0.5).sp))
                    Spacer(Modifier.height(10.dp))
                    ThinProgress(now.progressAt(c.clock), accent, 4.dp)
                    if (next != null) {
                        Spacer(Modifier.height(10.dp))
                        Text(c.str(CR.string.upNext, hm(next.startMs), next.title), maxLines = 1, overflow = TextOverflow.Ellipsis,
                            style = interStyle(12.sp, color = C.white60))
                    }
                } else {
                    Text(c.str(CR.string.noProgrammeInfo), style = interStyle(16.sp, FontWeight.SemiBold, C.white70))
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    c.str(if (canRestart) CR.string.remoteHintsWithStartOver else CR.string.remoteHints),
                    style = interStyle(12.sp, color = C.white38),
                )
            }
        }
    }
}

/** Kopfzeile: Zurück, Titel, Extras, dann Bildformat · Spuren · Schlaf-Timer · Neu starten · Info. */
@Composable
private fun TopBar(c: PlayerController, accent: Color, title: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color(0xCC000000), Color(0x00000000))))
            .padding(start = 12.dp, end = 16.dp, top = 12.dp, bottom = 40.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RoundBtn(Icons.back, accent, c.onExit)
        Spacer(Modifier.width(12.dp))
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, content = title)
        RoundBtn(Icons.aspect, accent, { c.sheet = Sheet.aspect }); Spacer(Modifier.width(8.dp))
        RoundBtn(Icons.subtitles, accent, { c.sheet = Sheet.tracks }); Spacer(Modifier.width(8.dp))
        RoundBtn(Icons.bedtime, accent, { c.sheet = Sheet.sleep }); Spacer(Modifier.width(8.dp))
        RoundBtn(Icons.restart, accent, { c.retry() })
        if (c.live) {
            Spacer(Modifier.width(8.dp))
            RoundBtn(Icons.info, accent, { c.showBar() })
        }
    }
}

// ---------------------------------------------------------------------------
// Film/Folge/Replay (_VodOverlay, _SeekBar, _ReplayBar)
// ---------------------------------------------------------------------------
@Composable
internal fun VodOverlay(c: PlayerController, accent: Color) {
    val r = c.req
    Column(Modifier.fillMaxSize()) {
        TopBar(c, accent) {
            Column(Modifier.weight(1f)) {
                Text(r.title.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis, style = interStyle(16.sp, FontWeight.SemiBold))
                r.subtitle?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, style = interStyle(12.sp, color = C.white70))
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (c.error == null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RoundBtn(Icons.replay10, accent, { c.seekBy(-10_000) }, size = 56.dp)
                    Spacer(Modifier.width(36.dp))
                    RoundBtn(if (c.userPaused) Icons.play else Icons.pause, accent, c::togglePause, size = 76.dp, focusRequester = c.mainFocus)
                    Spacer(Modifier.width(36.dp))
                    RoundBtn(Icons.forward10, accent, { c.seekBy(10_000) }, size = 56.dp)
                }
            }
        }
        Column(
            Modifier.fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color(0x00000000), Color(0xDD000000))))
                .padding(start = 32.dp, end = 32.dp, top = 40.dp, bottom = 28.dp),
        ) {
            r.catchup?.let { cu ->
                ReplayBar(c, cu.channel, cu.entry, accent)
                Spacer(Modifier.height(14.dp))
            }
            SeekBar(c, accent)
        }
    }
}

@Composable
private fun SeekBar(c: PlayerController, accent: Color) {
    val total = c.durationMs
    val pos = c.positionMs.coerceIn(0, if (total > 0) total else Long.MAX_VALUE)
    val style = interStyle(13.sp, color = C.white70).copy(fontFeatureSettings = "tnum")
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(fmtClock(pos), style = style)
        Box(Modifier.weight(1f).padding(horizontal = 16.dp)) {
            ThinProgress(if (total > 0) pos.toFloat() / total else 0f, accent, 4.dp)
        }
        Text(if (total <= 0) "--:--" else "-${fmtClock(total - pos)}", style = style)
    }
}

@Composable
private fun ReplayBar(c: PlayerController, ch: Channel, e: EpgEntry, accent: Color) {
    val running = e.isNowAt(c.clock)
    Row(verticalAlignment = Alignment.CenterVertically) {
        ChannelLogo(ch.name, ch.logoUrl, 38.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Tag(c.str(CR.string.replay), C.catchup, filled = true)
                Spacer(Modifier.width(10.dp))
                Text("${hm(e.startMs)} – ${hm(e.endMs)}" + if (running) "  ·  ${c.str(CR.string.onNowLower)}" else "",
                    style = interStyle(12.sp, color = C.white70))
            }
            Spacer(Modifier.height(4.dp))
            Text(e.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = interStyle(22.sp, FontWeight.Bold, family = PlayerType.InterDisplay))
        }
        PillBtn(Icons.skipPrevious, c.str(CR.string.previous), Color.White, accent, { c.replayStepAsync(-1) })
        Spacer(Modifier.width(8.dp))
        PillBtn(Icons.skipNext, c.str(CR.string.next), Color.White, accent, { c.replayStepAsync(1) })
        Spacer(Modifier.width(8.dp))
        PillBtn(Icons.circle, "LIVE", C.live, accent, c::goLive, filled = true)
    }
}

// ---------------------------------------------------------------------------
// Fehler (_ErrorBox)
// ---------------------------------------------------------------------------
@Composable
internal fun ErrorBox(c: PlayerController, message: String, accent: Color) {
    val kind = StreamError.classify(message)
    val geo = kind == StreamErrorKind.geoBlocked || kind == StreamErrorKind.forbidden
    val icon = when (kind) {
        StreamErrorKind.geoBlocked, StreamErrorKind.forbidden -> Icons.publicOff
        StreamErrorKind.unauthorized -> Icons.keyOff
        StreamErrorKind.notFound -> Icons.tvOff
        StreamErrorKind.blockedByApp -> Icons.gppBad
        else -> Icons.wifiBad
    }
    val title = c.str(when (kind) {
        StreamErrorKind.geoBlocked -> CR.string.notAvailableLocation
        StreamErrorKind.forbidden -> CR.string.noAccessChannel
        StreamErrorKind.unauthorized -> CR.string.loginDetailsRejected
        StreamErrorKind.notFound -> CR.string.channelNotFound
        StreamErrorKind.unreachable -> CR.string.serverUnreachable
        StreamErrorKind.blockedByApp -> CR.string.blockedSecurityReasons
        StreamErrorKind.other -> CR.string.streamCantPlayed
    })
    val body = c.str(when (kind) {
        StreamErrorKind.geoBlocked -> CR.string.providerHasBlocked
        StreamErrorKind.forbidden -> CR.string.possibleReasonsChannel
        StreamErrorKind.unauthorized -> CR.string.serverNoLonger
        StreamErrorKind.notFound -> CR.string.providerNoLonger
        StreamErrorKind.unreachable -> CR.string.checkInternetConnection
        StreamErrorKind.blockedByApp -> CR.string.streamsAddressInvalid
        StreamErrorKind.other -> CR.string.streamCouldntLoaded
    })
    val nextCh = c.live && c.channels.size > 1
    val focus = remember { FocusRequester() }
    LaunchedEffect(message) { runCatching { focus.requestFocus() } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 480.dp).padding(24.dp)
                .background(C.surface.copy(alpha = 0.94f), RoundedCornerShape(18.dp)).padding(26.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(icon, null, tint = if (geo) C.gold else C.live, modifier = Modifier.size(42.dp))
            Spacer(Modifier.height(12.dp))
            Text(title, textAlign = TextAlign.Center, style = interStyle(22.sp, FontWeight.Bold, C.text))
            Spacer(Modifier.height(8.dp))
            Text(body, textAlign = TextAlign.Center, style = interStyle(14.sp, color = C.textDim).copy(lineHeight = 20.sp))
            if (kind == StreamErrorKind.other) {
                Spacer(Modifier.height(8.dp))
                Text(message, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = interStyle(12.sp, color = C.textFaint))
            }
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (geo && nextCh) {
                    FilledBtn(Icons.skipNext, c.str(CR.string.nextChannel), accent, primary = true, focus = focus) { c.zapTo(c.index + 1) }
                    FilledBtn(Icons.refresh, c.str(CR.string.tryAgain), accent, primary = false) { c.retry() }
                } else {
                    FilledBtn(Icons.refresh, c.str(CR.string.tryAgain), accent, primary = true, focus = focus) { c.retry() }
                }
            }
        }
    }
}

@Composable
internal fun FilledBtn(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    accent: Color,
    primary: Boolean,
    focus: FocusRequester? = null,
    onClick: () -> Unit,
) {
    Tile(onClick, if (primary) Color.White else accent, radius = 12.dp, focusRequester = focus) { f ->
        Row(
            Modifier.background(if (primary) accent else if (f) C.surface3 else C.surface2, RoundedCornerShape(12.dp))
                .padding(horizontal = 22.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val fg = if (primary) C.onAccent else C.text
            Icon(icon, null, tint = fg, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(label, style = interStyle(15.sp, FontWeight.Bold, fg))
        }
    }
}

// ---------------------------------------------------------------------------
// Nächste Folge (NextEpisodeCard)
// ---------------------------------------------------------------------------
@Composable
internal fun NextEpisodeCard(c: PlayerController, accent: Color) {
    val n = c.nextUpData ?: return
    val play = remember { FocusRequester() }
    LaunchedEffect(n) { runCatching { play.requestFocus() } }
    Box(Modifier.fillMaxSize().padding(end = 48.dp, bottom = 56.dp), contentAlignment = Alignment.BottomEnd) {
        Column(
            Modifier.width(360.dp)
                .background(C.surface.copy(alpha = 0.96f), RoundedCornerShape(16.dp))
                .border(1.dp, C.line, RoundedCornerShape(16.dp))
                .padding(horizontal = 18.dp, vertical = 16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Spinner(accent, 22.dp, 2.5.dp, progress = c.nextUpSeconds / 10f)
                Spacer(Modifier.width(10.dp))
                Text(c.str(CR.string.nextEpisodeIn, c.nextUpSeconds), style = interStyle(14.sp, FontWeight.SemiBold, C.textDim))
            }
            Spacer(Modifier.height(10.dp))
            Text(c.str(CR.string.episodeSubtitle, n.season, n.number, n.title), maxLines = 2, overflow = TextOverflow.Ellipsis,
                style = interStyle(16.sp, FontWeight.SemiBold, C.text))
            Spacer(Modifier.height(14.dp))
            Row {
                Box(Modifier.weight(1f)) {
                    FilledBtn(Icons.play, c.str(CR.string.nextPlayNow), accent, primary = true, focus = play) { c.nextUpPlay() }
                }
                Spacer(Modifier.width(10.dp))
                FilledBtn(Icons.close, c.str(CR.string.cancel), accent, primary = false) { c.nextUpCancel() }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Ladegrafik, Schlaf-Timer-Warnung, Hinweis, Diagnose
// ---------------------------------------------------------------------------
@Composable
internal fun LoadingArt(c: PlayerController) {
    val r = c.req
    val ch = if (c.live) c.channels.getOrNull(c.index) else null
    val seed = c.nowOf(ch)?.title ?: r.title ?: ch?.name ?: ""
    val p = paletteFor(seed)
    Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(p[2].copy(alpha = 0.8f), p[1], p[0])))) {
        UrlPolicy.image(r.artworkUrl)?.let {
            AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)))
        if (ch != null) {
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                ChannelLogo(ch.name, ch.logoUrl, 64.dp)
                Spacer(Modifier.height(90.dp))
            }
        }
    }
}

@Composable
internal fun SleepWarning(c: PlayerController, accent: Color) {
    val at = c.sleepAtMs ?: return
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Box(Modifier.fillMaxSize().padding(bottom = 140.dp), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier.background(C.surface.copy(alpha = 0.95f), RoundedCornerShape(16.dp)).padding(start = 20.dp, top = 14.dp, bottom = 14.dp, end = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.bedtime, null, tint = C.gold)
            Spacer(Modifier.width(12.dp))
            Text(c.str(CR.string.sleepTimerStopIn, ((at - c.clock) / 1000).coerceIn(0, 60)), style = interStyle(15.sp, FontWeight.Bold))
            Spacer(Modifier.width(16.dp))
            FilledBtn(Icons.play, c.str(CR.string.continueWatching), accent, primary = true, focus = focus) { c.setSleep(0) }
        }
    }
}

@Composable
internal fun ToastView(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, accent: Color) {
    Box(Modifier.fillMaxWidth().padding(top = 90.dp), contentAlignment = Alignment.TopCenter) {
        Row(
            Modifier.background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(12.dp)).padding(horizontal = 18.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon ?: Icons.aspect, null, tint = accent, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(text, style = interStyle(15.sp, FontWeight.Bold))
        }
    }
}

@Composable
internal fun DebugPanel(lines: List<String>) {
    Column(Modifier.background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 8.dp)) {
        for (l in lines) Text(l, style = interStyle(12.sp, family = FontFamily.Monospace))
    }
}

/** Schlaf-Timer-Auswahl, Bildformat, Spuren, Varianten. */
@Composable
internal fun SheetFor(c: PlayerController, sheet: Sheet, accent: Color) {
    val focus = remember(sheet) { FocusRequester() }
    var rememberFlag by remember(sheet) { mutableStateOf(true) }
    val rows: List<SheetRow> = when (sheet) {
        Sheet.sleep -> buildList {
            val left = c.sleepAtMs?.let { (it - c.clock) / 60_000 + 1 }
            add(SheetRow.Header(c.str(CR.string.sleepTimer),
                if (left == null) c.str(CR.string.playbackStopsAutomatically) else c.str(CR.string.runsForMinutes, left)))
            val labels = mapOf(0 to CR.string.off, 15 to CR.string.fifteenMinutes, 30 to CR.string.thirtyMinutes,
                45 to CR.string.fortyFiveMinutes, 60 to CR.string.oneHour, 90 to CR.string.oneAndHalfHours, 120 to CR.string.twoHours)
            for (m in de.jasonstream.playback.logic.sleepChoicesMin) {
                add(SheetRow.Item(SheetItem(c.str(labels.getValue(m)), icon = if (m == 0) Icons.timerOff else Icons.bedtime,
                    selected = m == 0 && c.sleepAtMs == null) { c.setSleep(m) }))
            }
        }
        Sheet.aspect -> buildList {
            add(SheetRow.Header(c.str(CR.string.aspectRatio)))
            for (m in de.jasonstream.playback.logic.AspectMode.entries) {
                add(SheetRow.Item(SheetItem(c.aspectLabel(m), c.aspectHint(m), selected = m == c.aspect) { c.applyAspect(m, rememberFlag && c.aspectRememberLabel != null) }))
            }
            c.aspectRememberLabel?.let { l ->
                add(SheetRow.Divider)
                add(SheetRow.Item(SheetItem(l, icon = if (rememberFlag) Icons.checkOn else Icons.checkOff) { rememberFlag = !rememberFlag }))
            }
        }
        Sheet.tracks -> buildList {
            add(SheetRow.Header(c.str(CR.string.audioTrack)))
            c.audioTracks().forEach { t ->
                add(SheetRow.Item(SheetItem(
                    de.jasonstream.playback.logic.TrackLanguage.describe(t.info.language, t.info.title, c.str(CR.string.trackNumber, t.info.id)),
                    selected = t.selected,
                ) { c.selectTrack(androidx.media3.common.C.TRACK_TYPE_AUDIO, t) }))
            }
            add(SheetRow.Divider)
            add(SheetRow.Header(c.str(CR.string.subtitles)))
            val off = c.subtitlesOff()
            add(SheetRow.Item(SheetItem(c.str(CR.string.off), selected = off) { c.selectTrack(androidx.media3.common.C.TRACK_TYPE_TEXT, null) }))
            c.subtitleTracks().forEach { t ->
                add(SheetRow.Item(SheetItem(
                    de.jasonstream.playback.logic.TrackLanguage.describe(t.info.language, t.info.title, c.str(CR.string.trackNumber, t.info.id)),
                    selected = t.selected && !off,
                ) { c.selectTrack(androidx.media3.common.C.TRACK_TYPE_TEXT, t) }))
            }
        }
        Sheet.variants -> buildList {
            val ch = c.channels.getOrNull(c.index)
            val g = ch?.let { c.deps.variantIndex().groupOf(it.id) }
            if (g != null) {
                add(SheetRow.Header(c.str(CR.string.chooseVariant), c.str(CR.string.variantCount, g.size)))
                val current = c.playingVariantId
                for (m in g.members) {
                    add(SheetRow.Item(SheetItem(m.name, g.labelOf(m).takeIf { it != m.name }, selected = m.id == current) { c.pickVariant(m) }))
                }
            }
        }
    }
    LaunchedEffect(sheet) { runCatching { focus.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.38f)))
    OptionSheet(rows, accent, focus)
}

@Suppress("unused")
private val keepR = R.string.pl_info
