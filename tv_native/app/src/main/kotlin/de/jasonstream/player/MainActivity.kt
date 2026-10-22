package de.jasonstream.player

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Button
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import androidx.tv.material3.darkColorScheme
import coil3.compose.AsyncImage
import de.jasonstream.core.model.Channel
import java.text.DateFormat
import java.util.Date

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as JasonApp).container
        setContent {
            JasonTheme {
                val vm: MainViewModel = viewModel { MainViewModel(container) }
                HomeScreen(vm)
            }
        }
    }
}

private val Bg = Color(0xFF0B0E14)
private val Panel = Color(0xFF151A23)
private val Accent = Color(0xFF4FC3F7)
private val Muted = Color(0xFF9AA4B2)

@Composable
fun JasonTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(primary = Accent, background = Bg, surface = Panel),
        content = content,
    )
}

/**
 * Phase-1-Startseite: zeigt, dass Migration → Zwischenspeicher/Netz → Liste
 * funktioniert. Vollständig per Fernbedienung bedienbar (Fokus startet auf
 * „Aktualisieren“, Gruppen links, Sender rechts).
 */
@Composable
fun HomeScreen(vm: MainViewModel) {
    val s by vm.state.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    val firstFocus = remember { FocusRequester() }
    var selectedCat by rememberSaveable { mutableStateOf<String?>(null) }
    val catId = selectedCat?.takeIf { s.byCategory.containsKey(it) } ?: s.categories.firstOrNull()?.id
    val channels: List<Channel> = catId?.let { s.byCategory[it] } ?: emptyList()

    LaunchedEffect(Unit) { runCatching { firstFocus.requestFocus() } }

    Box(Modifier.fillMaxSize().background(Bg)) {
        // TV-Overscan: 5 % Rand (48 dp / 27 dp).
        Column(Modifier.fillMaxSize().padding(horizontal = 48.dp, vertical = 27.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Jason Stream Player", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Spacer(Modifier.width(12.dp))
                Text("${BuildConfig.VERSION_NAME} · nativ", color = Muted, fontSize = 14.sp)
                Spacer(Modifier.weight(1f))
                if (s.loading) Text(s.step, color = Accent, fontSize = 14.sp)
            }
            Spacer(Modifier.height(10.dp))
            val p = s.portal
            Text(
                if (p == null) "Kein Portal" else "${p.name}  ·  ${p.type.name.uppercase()}  ·  ${s.channelCount} Sender" +
                    "  ·  ${s.favorites} Favoriten" + (s.source?.let { "  ·  Quelle: $it" } ?: ""),
                color = Color.White, fontSize = 18.sp,
            )
            s.savedMs?.let {
                Text("Stand: ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it))}", color = Muted, fontSize = 13.sp)
            }
            Text(migrationText(s), color = Muted, fontSize = 13.sp)
            s.error?.let { Text(it, color = Color(0xFFFF8A80), fontSize = 14.sp) }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = vm::refresh, modifier = Modifier.focusRequester(firstFocus), enabled = p != null) {
                    Text("Aktualisieren")
                }
                if (s.portals.size > 1) {
                    Button(onClick = { selectedCat = null; vm.nextPortal() }) { Text("Nächstes Portal (${s.portals.size})") }
                }
            }
            Spacer(Modifier.height(16.dp))
            Row(Modifier.weight(1f)) {
                CategoryList(s.categories.map { it.id to it.name }, s.byCategory, catId, onFocus = { selectedCat = it })
                Spacer(Modifier.width(16.dp))
                ChannelList(channels) {
                    Toast.makeText(ctx, "Player folgt in Phase 2: ${it.name}", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
}

private fun migrationText(s: HomeState): String {
    val m = s.migration ?: return "Datenübernahme: –"
    if (m.error != null) return "Datenübernahme fehlgeschlagen (${m.error}) – wird beim nächsten Start erneut versucht."
    if (!m.sourceFound) return "Keine Daten der bisherigen App gefunden (Neuinstallation)."
    val unread = if (s.unreadableSecrets > 0) " · ${s.unreadableSecrets} Zugänge nicht lesbar – bitte neu anmelden" else ""
    return "Aus der bisherigen App übernommen: ${m.portals} Portale, ${m.favorites} Favoriten, " +
        "${m.myGroups} eigene Gruppen, ${m.keysCopied} Einstellungen$unread"
}

@Composable
private fun CategoryList(
    cats: List<Pair<String, String>>,
    byCategory: Map<String, List<Channel>>,
    selected: String?,
    onFocus: (String) -> Unit,
) {
    val state = rememberLazyListState()
    LazyColumn(
        state = state,
        modifier = Modifier.width(320.dp).fillMaxHeight().clip(RoundedCornerShape(12.dp)).background(Panel),
        contentPadding = PaddingValues(8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items(cats, key = { it.first }) { (id, name) ->
            ListItem(
                selected = id == selected,
                onClick = { onFocus(id) },
                headlineContent = { Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                trailingContent = { Text("${byCategory[id]?.size ?: 0}", color = Muted, fontSize = 12.sp) },
                modifier = Modifier.onFocusChanged { if (it.isFocused) onFocus(id) },
            )
        }
    }
}

@Composable
private fun ChannelList(channels: List<Channel>, onClick: (Channel) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(12.dp)).background(Panel),
        contentPadding = PaddingValues(8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items(channels, key = { it.id }) { ch ->
            ListItem(
                selected = false,
                onClick = { onClick(ch) },
                leadingContent = {
                    AsyncImage(
                        model = ch.logoUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.size(width = 56.dp, height = 32.dp),
                    )
                },
                headlineContent = { Text(ch.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = {
                    Text(
                        "Nr. ${ch.number}" + (if (ch.hasCatchup) " · Archiv ${ch.catchupDays} T" else "") +
                            (ch.epgId?.let { " · EPG $it" } ?: ""),
                        fontSize = 11.sp, maxLines = 1,
                    )
                },
            )
        }
    }
}
