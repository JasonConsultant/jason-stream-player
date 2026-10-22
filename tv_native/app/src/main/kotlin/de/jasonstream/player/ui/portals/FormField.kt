package de.jasonstream.player.ui.portals

import android.view.KeyEvent as AndroidKeyEvent
import android.view.ViewTreeObserver
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent

/**
 * Formular-Textfeld für die Fernbedienung (wie lib/ui/widgets/dpad_text_field.dart):
 * - Fokus allein öffnet keine Tastatur; **OK** startet die Eingabe.
 * - ▲▼ (und ◀ am Anfang / ▶ am Ende des Textes) verlassen das Feld.
 * - **Zurück** beendet eine laufende Eingabe (Tastatur zu); ohne Eingabe
 *   schließt Zurück wie gewohnt die Seite.
 * - Schließt die Bildschirmtastatur sich selbst (Zurück auf der Tastatur),
 *   endet die Eingabe sofort – das nächste Zurück verlässt die Seite.
 */
@Composable
fun FormTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    error: String? = null,
    helper: String? = null,
    placeholder: String = "",
    keyboardType: KeyboardType = KeyboardType.Text,
    password: Boolean = false,
    uppercase: Boolean = false,
    focusRequester: FocusRequester = remember { FocusRequester() },
) {
    var editing by remember { mutableStateOf(false) }
    var showPass by remember { mutableStateOf(false) }
    var tfv by remember { mutableStateOf(TextFieldValue(value, TextRange(value.length))) }
    if (tfv.text != value) tfv = TextFieldValue(value, TextRange(value.length)) // von außen geändert
    val field = remember { FocusRequester() }
    val kb = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val accent = LocalAccent.current.color
    val view = LocalView.current

    fun stop(move: FocusDirection?) {
        editing = false
        kb?.hide()
        runCatching { focusRequester.requestFocus() }
        if (move != null) focusManager.moveFocus(move)
    }
    val stopRef by rememberUpdatedState(::stop)

    LaunchedEffect(editing) {
        if (editing) {
            field.requestSoon()
            kb?.show()
        }
    }
    // Tastatur verschwindet (Zurück auf der Tastatur, „Ausblenden“) → Eingabe beenden.
    if (editing) {
        DisposableEffect(view) {
            var seen = false
            val l = ViewTreeObserver.OnGlobalLayoutListener {
                val vis = ViewCompat.getRootWindowInsets(view)?.isVisible(WindowInsetsCompat.Type.ime()) == true
                if (vis) seen = true else if (seen) { seen = false; stopRef(null) }
            }
            view.viewTreeObserver.addOnGlobalLayoutListener(l)
            onDispose { view.viewTreeObserver.removeOnGlobalLayoutListener(l) }
        }
    }

    Column(modifier) {
        Text(label, color = if (error != null) AppColors.live else AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 2.dp, bottom = 3.dp))
        Row(
            Modifier.fillMaxWidth()
                .focusRequester(focusRequester)
                .focusRing(if (error != null) AppColors.live else accent, focusedBg = AppColors.surface3, bg = AppColors.surface2, radius = 9.dp, width = 2.dp)
                .onPreviewKeyEvent { ev ->
                    // Passwort: ▶ am Feld (ohne Eingabe) schaltet Anzeigen/Verbergen um.
                    if (password && !editing && ev.nativeKeyEvent.keyCode == AndroidKeyEvent.KEYCODE_DPAD_RIGHT) {
                        if (ev.type == KeyEventType.KeyDown) showPass = !showPass
                        true
                    } else false
                }
                .tvClick { editing = true }
                .padding(horizontal = 11.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.weight(1f)) {
                if (tfv.text.isEmpty() && placeholder.isNotEmpty()) {
                    Text(placeholder, color = AppColors.textFaint, fontFamily = Inter, fontSize = 10.5.sp, maxLines = 1)
                }
                BasicTextField(
                    value = tfv,
                    onValueChange = {
                        val t = if (uppercase) it.copy(text = it.text.uppercase()) else it
                        tfv = t
                        if (t.text != value) onValueChange(t.text)
                    },
                    singleLine = true,
                    textStyle = TextStyle(color = AppColors.text, fontFamily = Inter, fontSize = 10.5.sp),
                    cursorBrush = SolidColor(accent),
                    visualTransformation = if (password && !showPass) PasswordVisualTransformation() else VisualTransformation.None,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = if (password) KeyboardType.Password else keyboardType,
                        imeAction = ImeAction.Next,
                        autoCorrectEnabled = false,
                        capitalization = if (uppercase) KeyboardCapitalization.Characters else KeyboardCapitalization.None,
                    ),
                    keyboardActions = KeyboardActions(onAny = { stop(FocusDirection.Down) }),
                    modifier = Modifier.fillMaxWidth()
                        .focusRequester(field)
                        .focusProperties { canFocus = editing }
                        .onFocusChanged { if (!it.isFocused && editing) editing = false }
                        .onPreviewKeyEvent { ev ->
                            val c = ev.nativeKeyEvent.keyCode
                            val down = ev.type == KeyEventType.KeyDown
                            val sel = tfv.selection
                            when {
                                c == AndroidKeyEvent.KEYCODE_BACK || c == AndroidKeyEvent.KEYCODE_ESCAPE -> {
                                    // Down und Up verbrauchen, sonst schließt die Seite gleich mit.
                                    if (!down) stop(null)
                                    true
                                }
                                c == AndroidKeyEvent.KEYCODE_DPAD_DOWN -> { if (down) stop(FocusDirection.Down); true }
                                c == AndroidKeyEvent.KEYCODE_DPAD_UP -> { if (down) stop(FocusDirection.Up); true }
                                c == AndroidKeyEvent.KEYCODE_DPAD_LEFT && sel.collapsed && sel.start <= 0 -> { if (down) stop(FocusDirection.Left); true }
                                c == AndroidKeyEvent.KEYCODE_DPAD_RIGHT && sel.collapsed && sel.start >= tfv.text.length -> { if (down) stop(FocusDirection.Right); true }
                                else -> false
                            }
                        },
                )
            }
            if (password) {
                Spacer(Modifier.width(6.dp))
                Icon(if (showPass) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, null, tint = AppColors.textFaint, modifier = Modifier.size(12.dp))
            }
        }
        val sub = error ?: helper
        if (sub != null) {
            Text(sub, color = if (error != null) AppColors.live else AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp, modifier = Modifier.padding(start = 2.dp, top = 2.dp))
        }
    }
}

/** Auswahl-Pille (Zugangsart). */
@Composable
fun ChoicePill(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val accent = LocalAccent.current.color
    Box(
        modifier
            .focusRing(Color.White, focusedBg = if (selected) accent else AppColors.surface3, bg = if (selected) accent.copy(alpha = 0.85f) else AppColors.surface2, radius = 14.dp, width = 1.5.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Text(label, color = if (selected) AppColors.onAccent else AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 10.sp)
    }
}
