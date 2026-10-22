package de.jasonstream.player.ui.search

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.SearchEngine
import de.jasonstream.player.logic.SearchResults
import de.jasonstream.player.logic.ShowHit
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.LocalShellFocus
import de.jasonstream.player.ui.common.ChannelLogo
import de.jasonstream.player.ui.common.EmptyHint
import de.jasonstream.player.ui.common.LiveBadge
import de.jasonstream.player.ui.common.LocalNow
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.hm
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.DpadTextField
import de.jasonstream.player.ui.start.LiveCard
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Eine Suche gleichzeitig (Suchlisten merken sich die letzte Suche). */
@OptIn(ExperimentalCoroutinesApi::class)
private val searchDispatcher = Dispatchers.Default.limitedParallelism(1)

/**
 * Suche (einfach): Sender und Sendungen, 250 ms Verzögerung beim Tippen,
 * letzte Suchen als Chips, Sprachsuche über RecognizerIntent.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SearchScreen(vm: AppViewModel) {
    val snap by vm.live.collectAsStateWithLifecycle()
    val epg by vm.epg.collectAsStateWithLifecycle()
    val recents by vm.recentSearches.collectAsStateWithLifecycle()
    val shell = LocalShellFocus.current
    val nowState = LocalNow.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val pinText = stringResource(R.string.enterPin)
    val remindText = stringResource(R.string.reminderActive)

    var query by rememberSaveable { mutableStateOf(vm.pendingSearch?.also { vm.pendingSearch = null } ?: "") }
    // Suchindex im Hintergrund (Sendungstitel einmal je Titel).
    val engine by produceState<SearchEngine?>(null, snap, epg) {
        value = withContext(searchDispatcher) { SearchEngine(snap.channels, epg.raw) }
    }
    val results by produceState(SearchResults.EMPTY, engine, query) {
        val e = engine ?: return@produceState
        delay(250) // Entprellen
        value = withContext(searchDispatcher) { e.search(query, nowState.value) }
    }

    val voiceIntent = remember {
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    }
    val voiceAvailable = remember { runCatching { voiceIntent.resolveActivity(ctx.packageManager) != null }.getOrDefault(false) }
    val voice = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            r.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let {
                query = it
                vm.addRecentSearch(it)
            }
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 32.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            DpadTextField(
                query, { query = it }, stringResource(R.string.channelProgrammeMovie),
                Modifier.width(420.dp).focusProperties { up = shell.menu },
                leading = Icons.Rounded.Search,
                onSubmit = { vm.addRecentSearch(it) },
                wrapperFocus = shell.content,
            )
            if (voiceAvailable) {
                Spacer(Modifier.width(8.dp))
                val accent = LocalAccent.current.color
                Box(
                    Modifier.size(30.dp).clip(RoundedCornerShape(15.dp))
                        .focusProperties { up = shell.menu }
                        .focusRing(accent, focusedBg = AppColors.surface3, bg = AppColors.surface2, radius = 15.dp, width = 2.dp)
                        .tvClick { runCatching { voice.launch(voiceIntent) } },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Rounded.Mic, stringResource(R.string.voiceSearch), tint = AppColors.text, modifier = Modifier.size(14.dp)) }
            }
        }
        if (recents.isNotEmpty()) {
            Text(stringResource(R.string.recentSearches), style = Type.small, modifier = Modifier.padding(top = 10.dp, bottom = 4.dp))
            LazyRow(Modifier.focusRestorer(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                items(recents, key = { it }) { q ->
                    SearchChip(q, Icons.Rounded.History, onLong = { vm.removeRecentSearch(q) }) { query = q }
                }
                item(key = "__clear") { SearchChip(stringResource(R.string.delete), null) { vm.clearRecentSearches() } }
            }
        }
        Spacer(Modifier.height(8.dp))
        val q = SearchEngine.normalize(query)
        when {
            q.length < SearchEngine.MIN_QUERY -> EmptyHint(stringResource(R.string.whatLooking), stringResource(R.string.least2Letters))
            results.isEmpty -> EmptyHint(stringResource(R.string.nothingFound))
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 20.dp)) {
                if (results.channels.isNotEmpty()) {
                    item(key = "ch_title") { Text(stringResource(R.string.channels), style = Type.rowTitle, modifier = Modifier.padding(vertical = 6.dp)) }
                    item(key = "ch_row") {
                        LazyRow(Modifier.focusRestorer(), horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                            items(results.channels, key = { it.id }) { c ->
                                LiveCard(c, epg) {
                                    vm.addRecentSearch(query)
                                    vm.play(it, snap.channelsOf(GroupIds.ALL), pinText)
                                }
                            }
                        }
                    }
                }
                if (results.shows.isNotEmpty()) {
                    item(key = "sh_title") { Text(stringResource(R.string.programmes), style = Type.rowTitle, modifier = Modifier.padding(top = 12.dp, bottom = 6.dp)) }
                    items(results.shows, key = { "${it.channel.id}_${it.entry.startMs}" }) { h ->
                        ShowRow(h, nowState.value) {
                            vm.addRecentSearch(query)
                            val n = System.currentTimeMillis()
                            when {
                                h.entry.isNowAt(n) -> vm.play(h.channel, snap.channelsOf(GroupIds.ALL), pinText)
                                h.entry.isPastAt(n) -> vm.playCatchup(h.channel, h.entry, pinText)
                                else -> scope.launch { vm.remind(h.channel, h.entry, remindText) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchChip(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, onLong: (() -> Unit)? = null, onClick: () -> Unit) {
    val accent = LocalAccent.current.color
    Row(
        Modifier.clip(RoundedCornerShape(10.dp))
            .focusRing(accent, focusedBg = AppColors.surface3, bg = AppColors.surface2, radius = 10.dp, width = 1.5.dp)
            .tvClick(onLongClick = onLong, onClick = onClick)
            .padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, tint = AppColors.textDim, modifier = Modifier.size(9.dp)); Spacer(Modifier.width(4.dp)) }
        Text(label, color = AppColors.text, fontFamily = Inter, fontSize = 8.5.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun ShowRow(h: ShowHit, now: Long, onClick: () -> Unit) {
    val accent = LocalAccent.current.color
    val e = h.entry
    Row(
        Modifier.fillMaxWidth().height(34.dp)
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 6.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ChannelLogo(h.channel.name, h.channel.logoUrl, height = 18.dp)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(e.title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${h.channel.name} · ${hm(e.startMs)} – ${hm(e.endMs)}", color = AppColors.textDim, fontFamily = Inter, fontSize = 8.sp, maxLines = 1)
        }
        when {
            e.isNowAt(now) -> LiveBadge(stringResource(R.string.onNowUpper))
            e.isPastAt(now) -> Badge(stringResource(R.string.replay), AppColors.catchup)
            else -> Badge(stringResource(R.string.upcoming), AppColors.textDim)
        }
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Box(Modifier.clip(RoundedCornerShape(3.dp)).background(color.copy(alpha = 0.18f)).padding(horizontal = 4.dp, vertical = 1.dp)) {
        Text(text, color = color, fontFamily = Inter, fontWeight = FontWeight.ExtraBold, fontSize = 7.sp, letterSpacing = 0.6.sp)
    }
}
