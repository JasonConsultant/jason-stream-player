package de.jasonstream.player.ui.portals

import android.app.Activity
import android.view.WindowManager
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.player.R as AppR
import de.jasonstream.player.logic.FieldError
import de.jasonstream.player.logic.FriendlyError
import de.jasonstream.player.logic.PortalField
import de.jasonstream.player.logic.PortalForm
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.dialogs.DialogButton
import de.jasonstream.player.ui.dialogs.OptionItem
import de.jasonstream.player.ui.dialogs.OptionsDialog
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Ergebnis von „Verbindung testen“ / „Speichern“. */
private sealed interface TestState {
    data object Idle : TestState
    data object Running : TestState
    data class Ok(val info: AccountInfo?) : TestState
    /** [saveFailed]: beim Speichern gescheitert → „Trotzdem speichern“ anbieten. */
    data class Failed(val text: String, val saveFailed: Boolean) : TestState
}

/** Bildschirmfotos/Vorschau im App-Wechsler sperren, solange Zugangsdaten sichtbar sind. */
@Composable
fun SecureScreen() {
    val ctx = LocalContext.current
    DisposableEffect(Unit) {
        val w = (ctx as? Activity)?.window
        w?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { w?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}

/** „Portal hinzufügen / bearbeiten“ (Port von add_portal_screen.dart, für die Fernbedienung). */
@Composable
fun PortalEditScreen(vm: AppViewModel, edit: Portal?) {
    SecureScreen()
    var form by remember { mutableStateOf(edit?.let { PortalForm.from(it) } ?: PortalForm()) }
    var errors by remember { mutableStateOf<Map<PortalField, FieldError>>(emptyMap()) }
    var test by remember { mutableStateOf<TestState>(TestState.Idle) }
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    val accent = LocalAccent.current.color
    val first = remember { FocusRequester() }
    val firstField = remember { FocusRequester() }
    LaunchedEffect(Unit) { (if (edit == null) first else firstField).requestSoon() }

    fun update(f: PortalForm) {
        form = f
        if (errors.isNotEmpty()) errors = f.validate()
        if (test !is TestState.Running) test = TestState.Idle
    }

    fun run(save: Boolean, force: Boolean = false) {
        val e = form.validate()
        errors = e
        if (e.isNotEmpty()) {
            test = TestState.Failed(ctx.getString(AppR.string.tv_fixFields), saveFailed = false)
            return
        }
        val p = form.toPortal(edit)
        fun done() {
            vm.savePortal(p)
            // Bearbeiten → zurück zur Liste; neu → gleich losschauen.
            if (edit != null) vm.popOverlay() else vm.closeOverlays()
        }
        if (force) return done()
        test = TestState.Running
        scope.launch {
            val r = vm.testPortal(p)
            r.onSuccess { info ->
                if (save) done() else test = TestState.Ok(info)
            }.onFailure { ex ->
                test = TestState.Failed(FriendlyError.of(ex).resolve(ctx.resources), saveFailed = save)
            }
        }
    }

    @Composable
    fun err(f: PortalField): String? = when (errors[f]) {
        null -> null
        FieldError.NameMissing -> stringResource(R.string.pleaseEnterName)
        FieldError.UrlMissing -> stringResource(
            when (form.type) {
                PortalType.m3u -> R.string.pleaseEnterPlaylist
                PortalType.stalker -> R.string.pleaseEnterPortal
                else -> R.string.pleaseEnterServer
            },
        )
        FieldError.UrlInvalid -> stringResource(R.string.pleaseEnterComplete)
        FieldError.Required -> stringResource(R.string.required)
        FieldError.MacFormat -> stringResource(R.string.macFormatHint)
        FieldError.EpgInvalid -> stringResource(R.string.invalidAddress)
    }

    Box(Modifier.fillMaxSize().background(AppColors.bg)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 32.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 520.dp).fillMaxWidth()) {
                Text(stringResource(if (edit != null) R.string.editPortal else R.string.addPortal), style = Type.title)
                Text(stringResource(AppR.string.tv_fieldHint), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp, modifier = Modifier.padding(top = 2.dp, bottom = 12.dp))

                Text(stringResource(R.string.loginType), color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 2.dp, bottom = 4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val types = listOf(PortalType.xtream to "Xtream Codes", PortalType.m3u to "M3U", PortalType.stalker to stringResource(R.string.macPortal))
                    for ((t, label) in types) {
                        ChoicePill(
                            label, selected = form.type == t,
                            modifier = if (t == PortalType.xtream) Modifier.focusRequester(first) else Modifier,
                        ) { update(form.copy(type = t)); errors = emptyMap() }
                    }
                }
                Spacer(Modifier.height(12.dp))

                val gap = Modifier.padding(bottom = 9.dp)
                FormTextField(
                    stringResource(AppR.string.tv_nameOptional), form.name, { update(form.copy(name = it)) }, gap,
                    error = err(PortalField.Name), placeholder = stringResource(R.string.portalNameHint),
                    focusRequester = firstField,
                )
                FormTextField(
                    stringResource(
                        when (form.type) {
                            PortalType.xtream -> R.string.serverUrlHttp
                            PortalType.stalker -> R.string.portalUrlE
                            else -> R.string.playlistUrlM3u
                        },
                    ),
                    form.url, { update(form.copy(url = it)) }, gap,
                    error = err(PortalField.Url), placeholder = "http://", keyboardType = KeyboardType.Uri,
                )
                if (form.unencrypted) {
                    Hint(Icons.Rounded.LockOpen, stringResource(R.string.unencryptedConnectionHttp), AppColors.gold, gap)
                }
                if (form.type == PortalType.xtream) {
                    FormTextField(stringResource(R.string.username), form.user, { update(form.copy(user = it)) }, gap, error = err(PortalField.User))
                    FormTextField(
                        stringResource(R.string.password), form.pass, { update(form.copy(pass = it)) }, gap,
                        error = err(PortalField.Pass), password = true,
                        helper = "▶ " + stringResource(R.string.showDisplay) + " / " + stringResource(R.string.hideConceal),
                    )
                }
                if (form.type == PortalType.stalker) {
                    FormTextField(
                        stringResource(R.string.macAddress), form.mac, { update(form.copy(mac = it)) }, gap,
                        error = err(PortalField.Mac), helper = stringResource(R.string.foundContractProviders),
                        placeholder = "00:1A:79:XX:XX:XX", uppercase = true,
                    )
                }
                FormTextField(
                    stringResource(R.string.epgUrlXmltv), form.epg, { update(form.copy(epg = it)) }, gap,
                    error = err(PortalField.Epg), keyboardType = KeyboardType.Uri,
                    helper = if (form.type == PortalType.xtream) stringResource(R.string.xtreamServerEpg) else null,
                )

                // Ergebnis des Tests / Fehler
                when (val t = test) {
                    TestState.Idle -> Unit
                    TestState.Running -> Hint(null, stringResource(AppR.string.tv_testing), AppColors.textDim, gap)
                    is TestState.Ok -> Hint(Icons.Rounded.CheckCircle, accountText(t.info), AppColors.catchup, gap)
                    is TestState.Failed -> Hint(Icons.Rounded.ErrorOutline, t.text, AppColors.live, gap)
                }

                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    val busy = test is TestState.Running
                    DialogButton(stringResource(if (busy) R.string.connecting else R.string.saveConnect), accent, primary = true) { if (!busy) run(save = true) }
                    DialogButton(stringResource(AppR.string.tv_testConnection), accent, primary = false) { if (!busy) run(save = false) }
                    val t = test
                    if (t is TestState.Failed && t.saveFailed) {
                        DialogButton(stringResource(AppR.string.tv_saveAnyway), accent, primary = false) { run(save = true, force = true) }
                    }
                    if (edit != null) {
                        Spacer(Modifier.weight(1f))
                        DialogButton(stringResource(R.string.delete), accent, primary = false) { confirmDelete = true }
                    }
                }
                Spacer(Modifier.height(14.dp))
                Hint(Icons.Rounded.VerifiedUser, stringResource(R.string.loginDetailsStored), AppColors.textFaint, Modifier, iconTint = AppColors.catchup)
            }
        }
    }

    if (confirmDelete && edit != null) {
        DeletePortalDialog(edit, onDismiss = { confirmDelete = false }) {
            vm.deletePortal(edit)
            vm.popOverlay()
        }
    }
}

@Composable
fun DeletePortalDialog(p: Portal, onDismiss: () -> Unit, onDelete: () -> Unit) {
    OptionsDialog(
        stringResource(R.string.deletePortalConfirm, p.name),
        listOf(
            OptionItem(stringResource(R.string.cancel)) {},
            OptionItem(stringResource(R.string.delete), Icons.Rounded.ErrorOutline) { onDelete() },
        ),
        onDismiss = onDismiss,
        subtitle = stringResource(R.string.loginDetailsFavourites),
    )
}

@Composable
private fun accountText(info: AccountInfo?): String {
    val ok = stringResource(AppR.string.tv_connectionOk)
    if (info == null) return ok
    val exp = info.expiresMs
    val valid = when {
        info.status.equals("Expired", true) -> stringResource(R.string.subscriptionExpired)
        exp == null -> stringResource(R.string.validIndefinitely)
        else -> stringResource(R.string.validUntil, DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(exp)))
    }
    return "$ok · $valid"
}

@Composable
private fun Hint(icon: ImageVector?, text: String, color: Color, modifier: Modifier, iconTint: Color = color) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.08f)).padding(horizontal = 9.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = iconTint, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(7.dp))
        }
        Text(text, color = if (color == AppColors.textFaint) AppColors.textFaint else AppColors.text, fontFamily = Inter, fontSize = 8.5.sp, lineHeight = 12.sp)
    }
}
