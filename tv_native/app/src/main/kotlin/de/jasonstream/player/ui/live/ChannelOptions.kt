package de.jasonstream.player.ui.live

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.jasonstream.core.R
import de.jasonstream.core.model.Channel
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.dialogs.OptionItem
import de.jasonstream.player.ui.dialogs.OptionsDialog
import de.jasonstream.player.ui.dialogs.TextInputDialog

private enum class Sub { Main, Groups, Variants, NewGroup }

/**
 * Lange OK / Menü-Taste auf einem Sender (wie channel_sheet.dart):
 * Favorit, Gruppen, Qualität/Quelle, Sperren, Verstecken.
 */
@Composable
fun ChannelOptions(vm: AppViewModel, c: Channel, pinText: String, onDismiss: () -> Unit) {
    val snap by vm.live.collectAsStateWithLifecycle()
    var sub by remember { mutableStateOf(Sub.Main) }
    val fav = snap.isFavorite(c)
    val locked = snap.isLocked(c)
    val group = snap.variantGroup(c)
    val added = stringResource(R.string.favouriteAddedNamed, c.name)
    val removed = stringResource(R.string.favouriteRemovedNamed, c.name)
    val hidden = stringResource(R.string.channelHidden, c.name)

    when (sub) {
        Sub.Main -> {
            val items = buildList {
                if (!snap.guest) add(OptionItem(stringResource(if (fav) R.string.favourite else R.string.addFavourites), if (fav) Icons.Rounded.Star else Icons.Rounded.StarBorder) {
                    vm.toggleFavorite(c, added, removed); onDismiss()
                })
                add(OptionItem(stringResource(R.string.groups), Icons.Rounded.Folder) { sub = Sub.Groups })
                if (group != null && group.size > 1) {
                    add(OptionItem(stringResource(R.string.chooseVariant), Icons.Rounded.Layers, detail = stringResource(R.string.variantCount, "${group.size}")) { sub = Sub.Variants })
                }
                add(OptionItem(stringResource(if (locked) R.string.locked else R.string.lock), if (locked) Icons.Rounded.Lock else Icons.Rounded.LockOpen) {
                    onDismiss(); vm.toggleLock(c, pinText)
                })
                add(OptionItem(stringResource(R.string.hideAction), Icons.Rounded.VisibilityOff) { vm.hideChannel(c, hidden); onDismiss() })
            }
            val subtitle = if (c.hasCatchup) stringResource(R.string.channelNumberCatchup, "${c.number}", "${c.catchupDays}")
            else stringResource(R.string.channelNumber, "${c.number}")
            OptionsDialog(c.name, items, onDismiss, subtitle = subtitle, closeOnClick = false)
        }
        Sub.Groups -> {
            val st = vm.storage
            val portal = vm.portal.value
            val groups = if (st != null && portal != null) st.myGroups(portal.id) else emptyList()
            val items = groups.map { g ->
                OptionItem(g.name, Icons.Rounded.Folder, checked = c.id in g.channels) { vm.toggleInGroup(c, g.id) }
            } + OptionItem(stringResource(R.string.newGroupEllipsis), Icons.Rounded.Add) { sub = Sub.NewGroup }
            OptionsDialog(
                stringResource(R.string.channelInGroups, c.name), items, onDismiss,
                subtitle = if (groups.isEmpty()) stringResource(R.string.noOwnGroups) else null,
                closeOnClick = false,
            )
        }
        Sub.Variants -> {
            val g = group ?: return onDismiss()
            val order = snap.playOrder(c)
            val chosen = order.firstOrNull()?.id
            val items = g.members.map { m ->
                OptionItem(
                    g.labelOf(m), Icons.Rounded.Layers, checked = m.id == chosen,
                    detail = if (m.id == g.best.id) stringResource(R.string.recommended) else null,
                ) { vm.chooseVariant(m) }
            }
            OptionsDialog(stringResource(R.string.chooseVariant), items, onDismiss, subtitle = c.name, initialIndex = g.members.indexOfFirst { it.id == chosen }.coerceAtLeast(0))
        }
        Sub.NewGroup -> TextInputDialog(
            stringResource(R.string.newGroup), stringResource(R.string.groupNameHint), stringResource(R.string.save),
            onConfirm = { vm.createGroup(it, c) },
            onDismiss = onDismiss,
        )
    }
}
