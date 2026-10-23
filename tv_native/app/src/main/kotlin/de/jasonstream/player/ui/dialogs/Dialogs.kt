package de.jasonstream.player.ui.dialogs

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Backspace
import androidx.compose.material.icons.rounded.Check
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
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.storage.Storage
import de.jasonstream.player.state.AppViewModel
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.platform.testTag
import de.jasonstream.player.ui.common.dpadList
import de.jasonstream.player.ui.common.keyGate
import de.jasonstream.player.ui.common.rememberDpadList
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent

// ---------------------------------------------------------------- Meldungen

@Composable
fun MessageHost(vm: AppViewModel, modifier: Modifier = Modifier) {
    val m by vm.message.collectAsStateWithLifecycle()
    val msg = m ?: return
    LaunchedEffect(msg) { vm.autoHide(msg) }
    Box(
        modifier.padding(bottom = 28.dp).clip(RoundedCornerShape(10.dp)).background(AppColors.surface3)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) { Text(msg.text, color = AppColors.text, fontFamily = Inter, fontSize = 10.sp, fontWeight = FontWeight.Medium) }
}

// ---------------------------------------------------------------- Auswahl-Dialog

data class OptionItem(
    val label: String,
    val icon: ImageVector? = null,
    val checked: Boolean? = null,
    val detail: String? = null,
    val onClick: () -> Unit,
)

/** Karte mit Titel und Liste (lange OK-Menüs, Auswahl). Zurück schließt. */
@Composable
fun OptionsDialog(
    title: String,
    items: List<OptionItem>,
    onDismiss: () -> Unit,
    subtitle: String? = null,
    width: Dp = 300.dp,
    initialIndex: Int = 0,
    closeOnClick: Boolean = true,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val listState = rememberLazyListState()
        val nav = rememberDpadList(listState, items.size)
        // Einstieg: gewählter Eintrag (auch wenn er weiter unten liegt → erst hinscrollen).
        LaunchedEffect(Unit) {
            val i = initialIndex.coerceIn(0, (items.size - 1).coerceAtLeast(0))
            if (i > 0) listState.scrollToItem((i - 2).coerceAtLeast(0))
            nav.index = i
            nav.requester(i).requestSoon()
        }
        val accent = LocalAccent.current.color
        Column(Modifier.keyGate().width(width).clip(RoundedCornerShape(14.dp)).background(AppColors.surface).padding(14.dp)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Text(subtitle, color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, modifier = Modifier.padding(top = 2.dp))
            Spacer(Modifier.height(8.dp))
            LazyColumn(
                Modifier.heightIn(max = 340.dp).testTag("options_list").dpadList(nav),
                state = listState, verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                itemsIndexed(items) { i, it ->
                    Row(
                        Modifier.fillMaxWidth()
                            .then(nav.item(i))
                            .focusRing(accent, focusedBg = AppColors.surface3, radius = 9.dp)
                            .tvClick { it.onClick(); if (closeOnClick) onDismiss() }
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (it.icon != null) {
                            Icon(it.icon, null, tint = AppColors.textDim, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(9.dp))
                        }
                        Column(Modifier.weight(1f)) {
                            Text(it.label, color = AppColors.text, fontFamily = Inter, fontSize = 10.5.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (it.detail != null) Text(it.detail, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.sp, maxLines = 2)
                        }
                        if (it.checked == true) Icon(Icons.Rounded.Check, null, tint = accent, modifier = Modifier.size(13.dp))
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Texteingabe

/**
 * Textfeld für die Fernbedienung: Fokus allein öffnet keine Tastatur,
 * erst OK („OK = tippen“). Zurück schließt die Tastatur, der Fokus bleibt.
 */
@Composable
fun DpadTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    leading: ImageVector? = null,
    onSubmit: (String) -> Unit = {},
    keyboardType: KeyboardType = KeyboardType.Text,
    wrapperFocus: FocusRequester = remember { FocusRequester() },
) {
    var editing by remember { mutableStateOf(false) }
    val field = remember { FocusRequester() }
    val kb = LocalSoftwareKeyboardController.current
    val accent = LocalAccent.current.color
    LaunchedEffect(editing) {
        if (editing) { field.requestSoon(); kb?.show() }
    }
    Row(
        modifier
            .focusRequester(wrapperFocus)
            .focusRing(accent, focusedBg = AppColors.surface3, bg = AppColors.surface2, radius = 10.dp, width = 2.dp)
            .tvClick { editing = true }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            Icon(leading, null, tint = AppColors.textDim, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(8.dp))
        }
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(placeholder, color = AppColors.textFaint, fontFamily = Inter, fontSize = 11.sp, maxLines = 1)
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = TextStyle(color = AppColors.text, fontFamily = Inter, fontSize = 11.sp),
                cursorBrush = SolidColor(accent),
                keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onAny = {
                    onSubmit(value); kb?.hide(); editing = false
                    runCatching { wrapperFocus.requestFocus() }
                }),
                modifier = Modifier.fillMaxWidth()
                    .focusRequester(field)
                    .focusProperties { canFocus = editing }
                    .onFocusChanged { if (!it.isFocused && editing) editing = false }
                    .onPreviewKeyEvent { ev ->
                        val c = ev.nativeKeyEvent.keyCode
                        if (ev.type == KeyEventType.KeyUp && (c == AndroidKeyEvent.KEYCODE_BACK || c == AndroidKeyEvent.KEYCODE_DPAD_DOWN || c == AndroidKeyEvent.KEYCODE_DPAD_UP)) {
                            editing = false
                            kb?.hide()
                            runCatching { wrapperFocus.requestFocus() }
                            true
                        } else c == AndroidKeyEvent.KEYCODE_BACK
                    },
            )
        }
    }
}

/** Kleiner Dialog mit Texteingabe (z. B. neue Gruppe). */
@Composable
fun TextInputDialog(title: String, hint: String, confirm: String, onConfirm: (String) -> Unit, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        var text by remember { mutableStateOf("") }
        val f = remember { FocusRequester() }
        LaunchedEffect(Unit) { f.requestSoon() }
        val accent = LocalAccent.current.color
        Column(Modifier.keyGate().width(320.dp).clip(RoundedCornerShape(14.dp)).background(AppColors.surface).padding(14.dp)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 13.sp)
            Spacer(Modifier.height(10.dp))
            DpadTextField(text, { text = it }, hint, Modifier.fillMaxWidth(), wrapperFocus = f, onSubmit = { if (it.isNotBlank()) { onConfirm(it); onDismiss() } })
            Spacer(Modifier.height(10.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                DialogButton(stringResource(R.string.cancel), accent, primary = false) { onDismiss() }
                Spacer(Modifier.width(8.dp))
                DialogButton(confirm, accent, primary = true) { if (text.isNotBlank()) { onConfirm(text); onDismiss() } }
            }
        }
    }
}

@Composable
fun DialogButton(label: String, accent: Color, primary: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(14.dp))
            .focusRing(Color.White, focusedBg = if (primary) accent else AppColors.surface3, bg = if (primary) accent else AppColors.surface2, radius = 14.dp, width = 1.5.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 7.dp),
    ) {
        Text(label, color = if (primary) AppColors.onAccent else AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 10.sp)
    }
}

// ---------------------------------------------------------------- PIN

@Composable
fun PinDialogHost(vm: AppViewModel) {
    val req by vm.pin.collectAsStateWithLifecycle()
    val r = req ?: return
    PinDialog(
        title = r.reason,
        create = r.create,
        verify = { vm.verifyPin(it) },
        onCreate = { vm.setPin(it); r.result.complete(true) },
        onResult = { r.result.complete(it) },
    )
}

/** PIN-Eingabe: Zifferntasten der Fernbedienung oder Tastenfeld (▲▼◀▶ + OK). */
@Composable
fun PinDialog(
    title: String,
    create: Boolean,
    verify: (String) -> Storage.PinResult,
    onCreate: (String) -> Unit,
    onResult: (Boolean) -> Unit,
) {
    Dialog(onDismissRequest = { onResult(false) }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        var pin by remember { mutableStateOf("") }
        var error by remember { mutableStateOf<String?>(null) }
        val accent = LocalAccent.current.color
        val first = remember { FocusRequester() }
        LaunchedEffect(Unit) { first.requestSoon() }
        val wrongOne = stringResource(R.string.pinWrongOneAttemptLeft)
        val wrongN = stringResource(R.string.pinWrongAttemptsLeft)
        val lockedIn = stringResource(R.string.pinLockedRetryIn)
        val minDigits = stringResource(R.string.least4Digits)
        fun submit() {
            if (create) {
                if (pin.length < 4) { error = minDigits; return }
                onCreate(pin)
                return
            }
            when (val res = verify(pin)) {
                Storage.PinResult.Ok -> onResult(true)
                is Storage.PinResult.Wrong -> {
                    pin = ""
                    error = if (res.attemptsLeft == 1) wrongOne else String.format(wrongN, res.attemptsLeft)
                }
                is Storage.PinResult.Locked -> {
                    pin = ""
                    val s = (res.forMs + 999) / 1000
                    error = String.format(lockedIn, if (s >= 60) "${(s + 59) / 60} min" else "$s s")
                }
            }
        }
        fun type(d: Char) { if (pin.length < 8) { pin += d; error = null } }
        Column(
            Modifier.keyGate().width(260.dp).clip(RoundedCornerShape(14.dp)).background(AppColors.surface).padding(16.dp)
                .onKeyEvent { ev ->
                    val c = ev.nativeKeyEvent.keyCode
                    if (ev.type == KeyEventType.KeyDown && c in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9) {
                        type('0' + (c - AndroidKeyEvent.KEYCODE_0)); true
                    } else if (ev.type == KeyEventType.KeyDown && c == AndroidKeyEvent.KEYCODE_DEL) {
                        pin = pin.dropLast(1); true
                    } else false
                },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(if (create) stringResource(R.string.createPin) else stringResource(R.string.enterPin), color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 13.sp)
            if (title.isNotEmpty()) Text(title, color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, maxLines = 2, modifier = Modifier.padding(top = 2.dp))
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.height(12.dp)) {
                repeat(maxOf(4, pin.length)) { i ->
                    Box(Modifier.size(10.dp).clip(CircleShape).background(if (i < pin.length) accent else AppColors.surface3))
                }
            }
            Text(error ?: (if (create) minDigits else " "), color = if (error != null) AppColors.live else AppColors.textFaint, fontFamily = Inter, fontSize = 8.5.sp, modifier = Modifier.padding(top = 6.dp))
            Spacer(Modifier.height(8.dp))
            val keys = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓")
            for (row in 0 until 4) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(bottom = 6.dp)) {
                    for (col in 0 until 3) {
                        val k = keys[row * 3 + col]
                        Box(
                            Modifier.size(44.dp, 30.dp)
                                .then(if (k == "1") Modifier.focusRequester(first) else Modifier)
                                .focusRing(accent, focusedBg = AppColors.surface3, bg = AppColors.surface2, radius = 8.dp, width = 2.dp)
                                .tvClick {
                                    when (k) {
                                        "⌫" -> pin = pin.dropLast(1)
                                        "✓" -> submit()
                                        else -> type(k[0])
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            when (k) {
                                "⌫" -> Icon(Icons.AutoMirrored.Rounded.Backspace, null, tint = AppColors.text, modifier = Modifier.size(13.dp))
                                "✓" -> Icon(Icons.Rounded.Check, null, tint = accent, modifier = Modifier.size(14.dp))
                                else -> Text(k, color = AppColors.text, fontFamily = Inter, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        }
    }
}
