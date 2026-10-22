package de.jasonstream.playback.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import de.jasonstream.core.R
import de.jasonstream.core.ui.AppPalette

/** Inter / InterDisplay (wie pubspec.yaml der Flutter-App). */
object PlayerType {
    val Inter = FontFamily(
        Font(R.font.inter_regular, FontWeight.Normal),
        Font(R.font.inter_medium, FontWeight.Medium),
        Font(R.font.inter_semibold, FontWeight.SemiBold),
        Font(R.font.inter_bold, FontWeight.Bold),
    )
    val InterDisplay = FontFamily(
        Font(R.font.interdisplay_semibold, FontWeight.SemiBold),
        Font(R.font.interdisplay_bold, FontWeight.Bold),
        Font(R.font.interdisplay_extrabold, FontWeight.ExtraBold),
    )
}

/** Compose-Farben aus [AppPalette]; Akzent kommt aus „set_accent“. */
internal object C {
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
    val white70 = Color.White.copy(alpha = 0.70f)
    val white60 = Color.White.copy(alpha = 0.60f)
    val white38 = Color.White.copy(alpha = 0.38f)
    val white24 = Color.White.copy(alpha = 0.24f)
    val white12 = Color.White.copy(alpha = 0.12f)
}
