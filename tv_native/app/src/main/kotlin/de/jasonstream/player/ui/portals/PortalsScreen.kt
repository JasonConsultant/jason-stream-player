package de.jasonstream.player.ui.portals

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.QrCode2
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.player.R as AppR
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.state.Overlay
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.platform.testTag
import de.jasonstream.player.ui.common.dpadList
import de.jasonstream.player.ui.common.rememberDpadList
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.OptionItem
import de.jasonstream.player.ui.dialogs.OptionsDialog
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type

@Composable
fun portalTypeLabel(t: PortalType) = when (t) {
    PortalType.xtream -> "Xtream"
    PortalType.m3u -> stringResource(R.string.m3uPlaylist)
    PortalType.stalker -> stringResource(R.string.macPortal)
    PortalType.demo -> stringResource(R.string.demo)
}

/** Einstellungen → Portale: hinzufügen, bearbeiten, löschen, aktiv setzen. */
@Composable
fun PortalsScreen(vm: AppViewModel) {
    val portals by vm.portals.collectAsStateWithLifecycle()
    val active by vm.portal.collectAsStateWithLifecycle()
    var menuFor by remember { mutableStateOf<Portal?>(null) }
    var deleteFor by remember { mutableStateOf<Portal?>(null) }
    val accent = LocalAccent.current
    // Slots: Portale, dann „Hinzufügen“, „Mit dem Handy“ (Lazy: Kopf, Portale, Abstand, Aktionen).
    val n = portals.size
    val listState = rememberLazyListState()
    val nav = rememberDpadList(listState, n + 2)
    nav.lazyIndexOf = { s -> if (s < n) s + 1 else s + 2 }
    LaunchedEffect(Unit) { nav.index = 0; nav.requester(0).requestSoon() }

    Box(Modifier.fillMaxSize().background(AppColors.bg), contentAlignment = Alignment.TopCenter) {
        LazyColumn(
            Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 32.dp).testTag("portal_list").dpadList(nav),
            state = listState,
            contentPadding = PaddingValues(top = 22.dp, bottom = 30.dp),
        ) {
            item {
                Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(bottom = 12.dp)) {
                    Text(stringResource(R.string.portals), style = Type.title, modifier = Modifier.weight(1f))
                    Text(stringResource(R.string.portalsSavedCount, "${portals.size}"), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp)
                }
            }
            items(portals, key = { it.id }) { p ->
                val isActive = p.id == active?.id
                val idx = portals.indexOf(p)
                Row(
                    Modifier.fillMaxWidth().padding(bottom = 4.dp)
                        .then(nav.item(idx))
                        .focusRing(accent.color, focusedBg = AppColors.rowFocus, bg = AppColors.surface, radius = 10.dp)
                        .tvClick(onLongClick = { menuFor = p }) { menuFor = p }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.Dns, null, tint = if (isActive) accent.color else AppColors.textDim, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(p.name, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(portalTypeLabel(p.type), color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1)
                    }
                    if (isActive) {
                        Text(
                            stringResource(R.string.activeBadge), color = AppColors.onAccent, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 7.sp, letterSpacing = 1.sp,
                            modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(accent.color).padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
            item { Spacer(Modifier.size(8.dp)) }
            item {
                ActionRow(Icons.Rounded.Add, stringResource(R.string.addPortal), stringResource(R.string.enterRemoteControl), nav.item(n)) {
                    vm.pushOverlay(Overlay.EditPortal(null))
                }
            }
            item {
                ActionRow(Icons.Rounded.QrCode2, stringResource(R.string.setUpPhone), stringResource(R.string.phoneTvSame), nav.item(n + 1)) {
                    vm.pushOverlay(Overlay.Pair)
                }
            }
        }
    }

    menuFor?.let { p ->
        val isActive = p.id == active?.id
        OptionsDialog(
            p.name,
            buildList {
                if (!isActive) add(OptionItem(stringResource(AppR.string.tv_setActive), Icons.Rounded.CheckCircle) { vm.switchPortal(p) })
                if (p.type != PortalType.demo) add(OptionItem(stringResource(R.string.edit), Icons.Rounded.Edit, detail = stringResource(R.string.editPortalHint)) { vm.pushOverlay(Overlay.EditPortal(p)) })
                add(OptionItem(stringResource(R.string.deletePortal), Icons.Rounded.Delete) { deleteFor = p })
            },
            onDismiss = { menuFor = null },
            subtitle = portalTypeLabel(p.type),
        )
    }
    deleteFor?.let { p -> DeletePortalDialog(p, onDismiss = { deleteFor = null }) { vm.deletePortal(p) } }
}

@Composable
private fun ActionRow(icon: ImageVector, title: String, subtitle: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val accent = LocalAccent.current.color
    Row(
        modifier.fillMaxWidth().padding(bottom = 4.dp)
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 10.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = accent, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp)
            Text(subtitle, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 1)
        }
    }
}
