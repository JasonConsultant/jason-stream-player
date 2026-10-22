package de.jasonstream.player.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.state.Overlay
import de.jasonstream.player.ui.portals.PairScreen
import de.jasonstream.player.ui.portals.PortalEditScreen
import de.jasonstream.player.ui.portals.PortalsScreen
import de.jasonstream.player.ui.portals.WelcomeScreen
import de.jasonstream.player.ui.common.ClockText
import de.jasonstream.player.ui.common.LocalNow
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.rememberTicker
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.MessageHost
import de.jasonstream.player.ui.dialogs.PinDialogHost
import de.jasonstream.player.ui.guide.GuideScreen
import de.jasonstream.player.ui.live.LiveScreen
import de.jasonstream.player.ui.search.SearchScreen
import de.jasonstream.player.ui.settings.SettingsScreen
import de.jasonstream.player.ui.start.StartScreen
import de.jasonstream.player.ui.start.VodPlaceholder
import de.jasonstream.player.ui.theme.Accent
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.JasonTheme
import de.jasonstream.player.ui.theme.LocalAccent

/**
 * Fokus-Anker der Shell: [menu] hängt am aktiven Menüpunkt, [content] am
 * Einstiegselement des aktiven Bildschirms. Bildschirme setzen
 * `focusProperties { up = shell.menu }` an ihrer obersten Zeile.
 */
@Immutable
class ShellFocus(val menu: FocusRequester, val content: FocusRequester)

val LocalShellFocus = staticCompositionLocalOf { ShellFocus(FocusRequester(), FocusRequester()) }

/** Versucht den Fokus einige Bilder lang (Listen sind evtl. noch nicht ausgelegt). */
suspend fun FocusRequester.requestSoon(tries: Int = 6): Boolean {
    repeat(tries) {
        if (runCatching { requestFocus() }.getOrDefault(false)) return true
        withFrameNanos { }
    }
    return false
}

/** Höhe des oberen Menüs (20 + 25 + 4 dp). */
val MENU_HEIGHT = 49.dp

@Composable
fun AppRoot(vm: AppViewModel, player: PlayerHost, onExit: () -> Unit, fixedNow: Long? = null) {
    val accentKey by vm.accent.collectAsStateWithLifecycle()
    val accent = remember(accentKey) { Accent(AppColors.accent(accentKey), accentKey) }
    val now = rememberTicker(fixed = fixedNow)
    JasonTheme(accent) {
        CompositionLocalProvider(LocalNow provides now) {
            Shell(vm, player, onExit)
        }
    }
}

@Composable
private fun Shell(vm: AppViewModel, player: PlayerHost, onExit: () -> Unit) {
    val shell by vm.shell.collectAsStateWithLifecycle()
    val focus = remember { ShellFocus(FocusRequester(), FocusRequester()) }
    val exitHint = stringResource(R.string.pressBackToExit)
    var menuHasFocus by remember { mutableStateOf(false) }
    var contentHasFocus by remember { mutableStateOf(false) }

    val overlays by vm.overlays.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val top = overlays.lastOrNull()
    val shellVisible = top == null && !status.noPortal

    // Zone aus dem Zustand → Fokus dorthin (Zurück, „Ansehen“ …).
    LaunchedEffect(shell.zone, shell.tab, shellVisible) {
        if (!shellVisible) return@LaunchedEffect
        when (shell.zone) {
            Zone.Menu -> if (!menuHasFocus) focus.menu.requestSoon()
            Zone.Content -> if (!contentHasFocus) {
                // Live TV: Fokus gehört dann dem Player (nie ins Menü ausweichen).
                if (!focus.content.requestSoon() && shell.tab != Tab.Live) focus.menu.requestSoon()
            }
        }
    }

    BackHandler { if (vm.back(exitHint)) onExit() }

    // Vollbild-Seiten (Portale, Kopplung) bzw. Willkommen ohne Portal – die
    // Shell wird dann nicht aufgebaut (kein Fokus „hinter“ der Seite).
    if (!shellVisible) {
        if (top != null) BackHandler { vm.popOverlay() } else BackHandler { onExit() }
        Box(Modifier.fillMaxSize().background(AppColors.bg)) {
            when (top) {
                null -> WelcomeScreen(vm)
                Overlay.Portals -> PortalsScreen(vm)
                is Overlay.EditPortal -> key(top) { PortalEditScreen(vm, top.portal) }
                Overlay.Pair -> PairScreen(vm)
            }
            MessageHost(vm, Modifier.align(Alignment.BottomCenter))
        }
        return
    }

    CompositionLocalProvider(LocalShellFocus provides focus) {
        Box(
            Modifier.fillMaxSize().background(AppColors.bg)
                // Fokus verloren (z. B. Liste neu geladen) → nächster Tastendruck holt ihn zurück.
                .onPreviewKeyEvent { ev ->
                    if (ev.type == KeyEventType.KeyDown && !menuHasFocus && !contentHasFocus && ev.key != Key.Back) {
                        runCatching { focus.content.requestFocus() }.getOrDefault(false) ||
                            runCatching { focus.menu.requestFocus() }.getOrDefault(false)
                    } else false
                },
        ) {
            val live = shell.tab == Tab.Live
            // Inhalt unter dem Menü; die Startseite reicht bis nach oben (Hero hinter dem Menü, Entwurf b1).
            Box(
                Modifier.fillMaxSize()
                    .padding(top = if (live || shell.tab == Tab.Start) 0.dp else MENU_HEIGHT)
                    .onFocusChanged {
                        contentHasFocus = it.hasFocus
                        if (it.hasFocus) vm.setZone(Zone.Content)
                    },
            ) {
                when (shell.tab) {
                    Tab.Start -> StartScreen(vm)
                    Tab.Live -> LiveScreen(vm, player, menuVisible = shell.zone == Zone.Menu)
                    Tab.Guide -> GuideScreen(vm, player)
                    Tab.Movies -> VodPlaceholder(series = false)
                    Tab.Series -> VodPlaceholder(series = true)
                    Tab.Search -> SearchScreen(vm)
                    Tab.Settings -> SettingsScreen(vm)
                }
            }
            if (!live) {
                TopMenu(shell.tab, vm, focus, Modifier.onFocusChanged {
                    menuHasFocus = it.hasFocus
                    if (it.hasFocus) vm.setZone(Zone.Menu)
                })
            }
            if (live && shell.zone == Zone.Menu) {
                // Menü über dem laufenden Video.
                Box(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xE6090B10), Color.Transparent)))) {
                    TopMenu(shell.tab, vm, focus, Modifier.padding(bottom = 24.dp).onFocusChanged {
                        menuHasFocus = it.hasFocus
                        if (it.hasFocus) vm.setZone(Zone.Menu)
                    })
                }
            }
            MessageHost(vm, Modifier.align(Alignment.BottomCenter))
            PinDialogHost(vm)
        }
    }
}

private data class MenuEntry(val tab: Tab, val label: Int)

private val menuEntries = listOf(
    MenuEntry(Tab.Start, R.string.navStart),
    MenuEntry(Tab.Live, R.string.liveTv),
    MenuEntry(Tab.Guide, R.string.tvGuide),
    MenuEntry(Tab.Movies, R.string.movies),
    MenuEntry(Tab.Series, R.string.series),
    MenuEntry(Tab.Search, R.string.search),
)

/** Oberes Menü (Entwurf b1): Bereiche als Pillen, rechts Uhr und Zahnrad. */
@Composable
fun TopMenu(selected: Tab, vm: AppViewModel, focus: ShellFocus, modifier: Modifier = Modifier) {
    val accent = LocalAccent.current
    Row(
        modifier.fillMaxWidth().padding(start = 32.dp, end = 32.dp, top = 20.dp, bottom = 4.dp).height(25.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        for (e in menuEntries) {
            MenuPill(
                label = stringResource(e.label),
                selected = e.tab == selected,
                search = e.tab == Tab.Search,
                accent = accent.color,
                modifier = Modifier
                    .then(if (e.tab == selected) Modifier.focusRequester(focus.menu) else Modifier)
                    .onPreviewKeyEvent { ev ->
                        // ▼ öffnet den fokussierten Bereich und geht in den Inhalt.
                        if (ev.key == Key.DirectionDown) {
                            if (ev.type == KeyEventType.KeyDown) vm.openFromMenu(e.tab)
                            true
                        } else false
                    },
                onClick = { vm.openFromMenu(e.tab) },
            )
        }
        Spacer(Modifier.weight(1f))
        ClockText()
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier.size(22.dp)
                .then(if (selected == Tab.Settings) Modifier.focusRequester(focus.menu) else Modifier)
                .onPreviewKeyEvent { ev ->
                    if (ev.key == Key.DirectionDown) {
                        if (ev.type == KeyEventType.KeyDown) vm.openFromMenu(Tab.Settings)
                        true
                    } else false
                }
                .focusRing(accent.color, focusedBg = AppColors.surface3, bg = if (selected == Tab.Settings) Color.White else Color.Transparent, radius = 11.dp)
                .tvClick { vm.openFromMenu(Tab.Settings) },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Settings, stringResource(R.string.settings), tint = if (selected == Tab.Settings) AppColors.bg else AppColors.textDim, modifier = Modifier.size(12.dp))
        }
    }
}

@Composable
private fun MenuPill(label: String, selected: Boolean, search: Boolean, accent: Color, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .clip(RoundedCornerShape(15.dp))
            .focusRing(accent, focusedBg = if (selected) Color.White else AppColors.surface3, bg = if (selected) Color.White else Color.Transparent, radius = 15.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val color = if (selected) Color(0xFF0B0D12) else AppColors.textDim
        if (search) {
            Icon(Icons.Rounded.Search, null, tint = color, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(4.dp))
        }
        Text(label, color = color, fontFamily = Inter, fontSize = 11.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium, maxLines = 1)
    }
}
