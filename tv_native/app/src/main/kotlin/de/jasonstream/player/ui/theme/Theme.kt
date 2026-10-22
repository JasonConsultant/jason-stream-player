package de.jasonstream.player.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme
import de.jasonstream.core.R as CoreR
import de.jasonstream.core.ui.AppPalette

/** Farben der App (lib/core/theme.dart AppColors; Werte aus [AppPalette]). */
object AppColors {
    val bg = Color(AppPalette.bg)
    val surface = Color(AppPalette.surface)
    val surface2 = Color(AppPalette.surface2)
    val surface3 = Color(AppPalette.surface3)
    val line = Color(AppPalette.line)
    val text = Color(AppPalette.text)
    val textDim = Color(AppPalette.textDim)
    val textFaint = Color(AppPalette.textFaint)
    val live = Color(AppPalette.live)
    val catchup = Color(AppPalette.catchup)
    val gold = Color(AppPalette.gold)
    val onAccent = Color(AppPalette.onAccent)

    /** Fokus-Hintergrund von Listenzeilen (Entwurf a1: #20263a ≈ surface3 + Akzentring). */
    val rowFocus = Color(0xFF20263A)
    val rowSelected = Color(0xFF1B2030)
    val cell = Color(0xFF141925)
    val cellNow = Color(0xFF1B2131)
    val nowLine = Color(0xFFFF5252)
    val track = Color(0x1AFFFFFF)

    fun accent(key: String?) = Color(AppPalette.accent(key))
}

/** Akzentfarbe (Einstellung „set_accent“) – ändert sich selten, daher statisch. */
@Immutable
data class Accent(val color: Color, val key: String) {
    val soft: Color get() = color.copy(alpha = 0x33 / 255f)
}

val LocalAccent = staticCompositionLocalOf { Accent(AppColors.accent(null), AppPalette.DEFAULT_ACCENT) }

/** Inter / Inter Display aus :core (vom Player-Modul bereitgestellt). */
val Inter = FontFamily(
    Font(CoreR.font.inter_regular, FontWeight.Normal),
    Font(CoreR.font.inter_medium, FontWeight.Medium),
    Font(CoreR.font.inter_semibold, FontWeight.SemiBold),
    Font(CoreR.font.inter_bold, FontWeight.Bold),
)

val InterDisplay = FontFamily(
    Font(CoreR.font.interdisplay_semibold, FontWeight.SemiBold),
    Font(CoreR.font.interdisplay_bold, FontWeight.Bold),
    Font(CoreR.font.interdisplay_extrabold, FontWeight.ExtraBold),
)

/** Schriftgrößen nach den Entwürfen (px / 2 = dp bei 1080p). */
object Type {
    private val base = TextStyle(fontFamily = Inter, color = AppColors.text)
    val hero = TextStyle(fontFamily = InterDisplay, fontWeight = FontWeight.ExtraBold, fontSize = 27.sp, letterSpacing = (-0.5).sp, color = AppColors.text)
    val title = base.copy(fontFamily = InterDisplay, fontWeight = FontWeight.Bold, fontSize = 19.sp, letterSpacing = (-0.3).sp)
    val rowTitle = base.copy(fontWeight = FontWeight.Bold, fontSize = 11.sp)
    val menu = base.copy(fontWeight = FontWeight.Medium, fontSize = 11.sp, color = AppColors.textDim)
    val body = base.copy(fontSize = 10.sp, color = AppColors.textDim)
    val item = base.copy(fontWeight = FontWeight.SemiBold, fontSize = 10.5.sp)
    val small = base.copy(fontSize = 8.sp, color = AppColors.textDim)
    val tiny = base.copy(fontSize = 7.sp, color = AppColors.textFaint)
    val kicker = base.copy(fontWeight = FontWeight.Bold, fontSize = 7.5.sp, letterSpacing = 1.5.sp)
}

@Composable
fun JasonTheme(accent: Accent, content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = accent.color,
            onPrimary = AppColors.onAccent,
            secondary = AppColors.catchup,
            background = AppColors.bg,
            surface = AppColors.surface,
            onSurface = AppColors.text,
            surfaceVariant = AppColors.surface2,
            error = AppColors.live,
        ),
    ) {
        CompositionLocalProvider(LocalAccent provides accent, content = content)
    }
}
