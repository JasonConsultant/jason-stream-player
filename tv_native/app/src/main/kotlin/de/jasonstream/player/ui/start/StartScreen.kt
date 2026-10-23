package de.jasonstream.player.ui.start

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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.platform.testTag
import de.jasonstream.player.ui.common.DpadList
import de.jasonstream.player.ui.common.dpadList
import de.jasonstream.player.ui.common.probe
import de.jasonstream.player.ui.common.rememberDpadList
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.player.R as AppR
import de.jasonstream.player.logic.EpgIndex
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.LiveSnapshot
import de.jasonstream.player.logic.SportDetector
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.LocalShellFocus
import de.jasonstream.player.ui.common.ChannelLogo
import de.jasonstream.player.ui.common.EmptyHint
import de.jasonstream.player.ui.common.EpgProgress
import de.jasonstream.player.ui.common.Kicker
import de.jasonstream.player.ui.common.LocalNow
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.generatedArt
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.DialogButton
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Titel „Reihe: Folge“ → (Folge, Reihe) für die große Überschrift. */
fun splitTitle(t: String): Pair<String, String?> {
    val i = t.indexOf(": ")
    if (i <= 0 || i > 60 || i >= t.length - 3) return t to null
    return t.substring(i + 2) to t.substring(0, i)
}

@Composable
fun StartScreen(vm: AppViewModel) {
    val snap by vm.live.collectAsStateWithLifecycle()
    val epg by vm.epg.collectAsStateWithLifecycle()
    val rev by vm.epgRevision.collectAsStateWithLifecycle()
    val current by vm.current.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val nowState = LocalNow.current
    // Nur bei Wechsel des 5-Minuten-Fensters bzw. der Sendung neu aufbauen (nicht bei jedem Uhr-Tick).
    val bucket by remember { derivedStateOf { nowState.value / (5 * 60_000) } }
    val pinText = stringResource(R.string.enterPin)

    // Sport jetzt: im Hintergrund (große Listen), alle 5 Minuten neu.
    val sport by produceState(emptyList<Channel>(), snap, epg, rev, bucket) {
        value = withContext(Dispatchers.Default) { liveSport(snap, epg, System.currentTimeMillis()) }
    }

    if (status.noPortal) {
        NoPortal(vm)
        return
    }
    val hero = current
    val heroEntry by remember(hero, epg, rev) { derivedStateOf { hero?.let { epg.nowNext(it, nowState.value).now } } }
    val recents = snap.recentChannels
    val favs = snap.favoriteChannels
    val shell = LocalShellFocus.current
    probe("StartScreen")

    // Senkrecht: Slots = Hero + vorhandene Reihen (Lazy-Index = Slot). Jede Reihe
    // führt ◀▶ selbst und merkt sich ihre Karte; ▲▼ springt genau eine Reihe.
    val heroNav = rememberDpadList(null, if (hero != null && heroEntry != null && hero.hasCatchup) 2 else 1, vertical = false)
    val recentsNav = rememberDpadList(rememberLazyListState(), recents.size, vertical = false)
    val favsNav = rememberDpadList(rememberLazyListState(), favs.size, vertical = false)
    val sportNav = rememberDpadList(rememberLazyListState(), sport.size, vertical = false)
    val rowNavs = buildList {
        add(heroNav)
        if (recents.isNotEmpty()) add(recentsNav)
        if (favs.isNotEmpty()) add(favsNav)
        if (sport.isNotEmpty()) add(sportNav)
    }
    val listState = rememberLazyListState()
    val nav = rememberDpadList(listState, rowNavs.size)
    nav.requestSlot = { r -> rowNavs.getOrNull(r)?.let { it.focus(it.index); true } ?: false }

    LazyColumn(
        Modifier.fillMaxSize().testTag("start_list")
            // ▲ am Hero: weiter ins Menü (focusProperties up); ▼ an der letzten Reihe: Ende.
            .dpadList(nav) { dir -> dir > 0 },
        state = listState,
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item(key = "hero") {
            Hero(
                channel = hero,
                entry = heroEntry,
                onWatch = { hero?.let { vm.play(it, snap.channelsOf(GroupIds.ALL), pinText) } },
                onFromStart = { e -> hero?.let { vm.playCatchup(it, e, pinText) } },
                modifier = nav.item(0).testTag("start_hero").dpadList(heroNav),
                entryModifier = Modifier.focusRequester(shell.content).focusProperties { up = shell.menu }.then(heroNav.item(0)),
                secondModifier = heroNav.item(1),
            )
        }
        var slot = 1
        if (recents.isNotEmpty()) { val r = slot++; item(key = "recents") {
            ChannelRow(stringResource(AppR.string.tv_continueLive), recents, epg, recentsNav, nav.item(r).testTag("start_recents")) { vm.play(it, recents, pinText) }
        } }
        if (favs.isNotEmpty()) { val r = slot++; item(key = "favs") {
            ChannelRow(stringResource(R.string.favourites), favs, epg, favsNav, nav.item(r).testTag("start_favs")) { vm.play(it, favs, pinText) }
        } }
        if (sport.isNotEmpty()) { val r = slot++; item(key = "sport") {
            ChannelRow(stringResource(R.string.homeLiveSport), sport, epg, sportNav, nav.item(r).testTag("start_sport")) { vm.play(it, sport, pinText) }
        } }
        item(key = "vod") { ContinueWatchingPlaceholder() }
    }
}

/** Sender, auf denen gerade Sport läuft (höchstens 30). */
fun liveSport(snap: LiveSnapshot, epg: EpgIndex, now: Long, max: Int = 30): List<Channel> {
    val out = ArrayList<Channel>()
    val sportGroup = HashMap<String, Boolean>()
    for (c in snap.channels) {
        val e = epg.nowNext(c, now).now ?: continue
        val g = sportGroup.getOrPut(c.categoryId) { SportDetector.isSportGroup(snap.categoryName(c.categoryId)) }
        if (SportDetector.isSportProgramme(e.title, e.genre, g)) {
            out.add(c)
            if (out.size >= max) break
        }
    }
    return out
}

@Composable
private fun Hero(
    channel: Channel?,
    entry: EpgEntry?,
    onWatch: () -> Unit,
    onFromStart: (EpgEntry) -> Unit,
    modifier: Modifier,
    entryModifier: Modifier,
    secondModifier: Modifier = Modifier,
) {
    val accent = LocalAccent.current
    val seed = channel?.name ?: "jason"
    val art = remember(seed) { generatedArt(seed) }
    Box(modifier.fillMaxWidth().height(320.dp)) {
        // Hintergrund (generierte Grafik des Senders), zum Text und nach unten ausgeblendet.
        Box(Modifier.fillMaxSize().background(art))
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to AppColors.bg, 0.45f to AppColors.bg.copy(alpha = 0.6f), 0.7f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to AppColors.bg.copy(alpha = 0.5f), 0.25f to Color.Transparent, 0.6f to Color.Transparent, 1f to AppColors.bg)))
        Column(Modifier.padding(start = 32.dp, top = 110.dp).widthIn(max = 460.dp)) {
            if (channel != null) {
                Kicker("${stringResource(AppR.string.tv_nowLive)} · ${channel.name}")
                val (head, prefix) = remember(entry?.title) { splitTitle(entry?.title ?: channel.name) }
                Text(
                    head, style = Type.hero, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 6.dp, bottom = 6.dp),
                )
                HeroSub(entry, prefix)
                Row(Modifier.padding(top = 13.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Row(
                        entryModifier.clip(RoundedCornerShape(15.dp))
                            .focusRing(Color.White, focusedBg = accent.color, bg = accent.color, radius = 15.dp, width = 1.5.dp)
                            .tvClick(onClick = onWatch)
                            .padding(horizontal = 15.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Rounded.PlayArrow, null, tint = AppColors.onAccent, modifier = Modifier.size(12.dp))
                        Spacer(Modifier.width(3.dp))
                        Text(stringResource(R.string.watch), color = AppColors.onAccent, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 10.sp)
                    }
                    if (entry != null && channel.hasCatchup) {
                        DialogButton(stringResource(R.string.fromStart), accent.color, primary = false, secondModifier) { onFromStart(entry) }
                    }
                }
            } else {
                Text(stringResource(R.string.loadingSavedData), style = Type.title)
                Box(entryModifier.size(1.dp).tvClick { })
            }
        }
    }
}

@Composable
private fun HeroSub(entry: EpgEntry?, prefix: String?) {
    val now by LocalNow.current
    val left = entry?.let { ((it.endMs - now) / 60_000).coerceAtLeast(0) }
    val parts = listOfNotNull(prefix, entry?.genre?.takeIf { it != prefix }, left?.let { stringResource(R.string.minutesLeft, "$it") })
    Text(
        if (entry == null) stringResource(R.string.noProgrammeInfo) else parts.joinToString(" · "),
        color = Color(0xFFC3C8D4), fontFamily = Inter, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun ChannelRow(title: String, channels: List<Channel>, epg: EpgIndex, nav: DpadList, modifier: Modifier = Modifier, onClick: (Channel) -> Unit) {
    Column(modifier.padding(top = 10.dp)) {
        Text(title, style = Type.rowTitle, modifier = Modifier.padding(start = 32.dp, bottom = 8.dp))
        LazyRow(
            Modifier.dpadList(nav),
            state = nav.lazy!!,
            contentPadding = PaddingValues(horizontal = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            itemsIndexed(channels, key = { _, c -> c.id }) { i, c -> LiveCard(c, epg, nav.item(i), onClick) }
        }
    }
}

/** Karte „Weiter mit Live TV“: Grafik/Logo, Name, laufende Sendung, Fortschritt. */
@Composable
fun LiveCard(c: Channel, epg: EpgIndex, modifier: Modifier = Modifier, onClick: (Channel) -> Unit) {
    val accent = LocalAccent.current.color
    val nowState = LocalNow.current
    val entry by remember(c, epg) { derivedStateOf { epg.nowNext(c, nowState.value).now } }
    val art = remember(c.name) { generatedArt(c.name) }
    Box(
        modifier.size(170.dp, 96.dp).clip(RoundedCornerShape(7.dp)).background(art)
            .focusRing(accent, radius = 7.dp, width = 2.dp)
            .tvClick { onClick(c) },
    ) {
        ChannelLogo(c.name, c.logoUrl, Modifier.padding(8.dp), height = 18.dp)
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xD9000000))))
                .padding(horizontal = 7.dp, vertical = 6.dp),
        ) {
            Text(c.name, color = Color.White, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 9.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(entry?.title ?: "", color = Color(0xFFE0E3EA), fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (entry != null) EpgProgress(entry, Modifier.fillMaxWidth().padding(top = 3.dp), height = 2.dp)
        }
    }
}

@Composable
private fun ContinueWatchingPlaceholder() {
    Column(Modifier.padding(top = 14.dp, start = 32.dp)) {
        Text(stringResource(R.string.continueWatching), style = Type.rowTitle, modifier = Modifier.padding(bottom = 8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            for (i in 0 until 6) {
                Box(Modifier.size(90.dp, 52.dp).clip(RoundedCornerShape(6.dp)).background(generatedArt("vod$i")))
            }
        }
        Text(stringResource(AppR.string.tv_vodSoon), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun NoPortal(vm: AppViewModel) {
    val shell = LocalShellFocus.current
    val accent = LocalAccent.current.color
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        EmptyHint(stringResource(AppR.string.tv_noPortalTitle), stringResource(AppR.string.tv_noPortalText))
        DialogButton(
            stringResource(R.string.tryDemo), accent, primary = true,
            modifier = Modifier.focusRequester(shell.content).focusProperties { up = shell.menu },
        ) { vm.addDemoPortal() }
    }
}

/** Filme/Serien folgen in Phase 3. */
@Composable
fun VodPlaceholder(series: Boolean) {
    val shell = LocalShellFocus.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            EmptyHint(stringResource(if (series) R.string.series else R.string.movies), stringResource(AppR.string.tv_vodSoon))
            // Unsichtbarer Fokus-Anker, damit ▼/▲ im Menü nicht ins Leere geht.
            Box(Modifier.size(1.dp).focusRequester(shell.content).focusProperties { up = shell.menu }.tvClick { })
        }
    }
}
