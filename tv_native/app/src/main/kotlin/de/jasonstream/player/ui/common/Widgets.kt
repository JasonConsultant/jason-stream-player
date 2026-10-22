package de.jasonstream.player.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.InterDisplay
import de.jasonstream.player.ui.theme.LocalAccent
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ---------------------------------------------------------------- Uhr

/**
 * Aktuelle Zeit als State – wird nur in der Zeichenphase (Fortschritt,
 * Jetzt-Linie) oder in kleinen Text-Bausteinen gelesen, damit das Ticken
 * keine ganzen Bildschirme neu aufbaut.
 */
val LocalNow = compositionLocalOf<State<Long>> { error("LocalNow fehlt") }

@Composable
fun rememberTicker(periodMs: Long = 15_000, fixed: Long? = null): State<Long> {
    val s: MutableState<Long> = remember { androidx.compose.runtime.mutableStateOf(fixed ?: System.currentTimeMillis()) }
    if (fixed == null) {
        LaunchedEffect(Unit) {
            while (true) {
                s.value = System.currentTimeMillis()
                delay(periodMs - System.currentTimeMillis() % periodMs)
            }
        }
    }
    return s
}

private val hmFormat = object : ThreadLocal<SimpleDateFormat>() {
    override fun initialValue() = SimpleDateFormat("HH:mm", Locale.getDefault())
}

fun hm(t: Long): String = hmFormat.get()!!.format(Date(t))

/** Uhrzeit oben rechts – eigener Neuaufbau nur dieses Texts. */
@Composable
fun ClockText(modifier: Modifier = Modifier) {
    val now by LocalNow.current
    val minute = now / 60_000
    Text(remember(minute) { hm(now) }, modifier = modifier, color = AppColors.textDim, fontSize = 11.sp, fontFamily = Inter)
}

// ---------------------------------------------------------------- Fortschritt

/**
 * Dünner Fortschrittsbalken einer Sendung; liest die Uhr in der
 * Zeichenphase (kein Neuaufbau bei jedem Tick).
 */
@Composable
fun EpgProgress(entry: EpgEntry?, modifier: Modifier = Modifier, height: Dp = 2.dp, color: Color = LocalAccent.current.color) {
    val now = LocalNow.current
    Canvas(modifier.height(height)) {
        val r = size.height / 2
        drawRoundRect(AppColors.track, cornerRadius = CornerRadius(r, r))
        val f = entry?.progressAt(now.value) ?: 0f
        if (f > 0f) drawRoundRect(color, size = Size(size.width * f, size.height), cornerRadius = CornerRadius(r, r))
    }
}

/** Balken mit festem Wert (0–1). */
@Composable
fun ThinProgress(value: Float, modifier: Modifier = Modifier, height: Dp = 2.dp, color: Color = LocalAccent.current.color) {
    Canvas(modifier.height(height)) {
        val r = size.height / 2
        drawRoundRect(AppColors.track, cornerRadius = CornerRadius(r, r))
        if (value > 0f) drawRoundRect(color, Offset.Zero, Size(size.width * value.coerceIn(0f, 1f), size.height), CornerRadius(r, r))
    }
}

// ---------------------------------------------------------------- Sender-Logo

private val palettes = listOf(
    listOf(0xFF1B2A6B, 0xFF6A3DE8, 0xFFFF7A45), listOf(0xFF0E3B43, 0xFF1F8A70, 0xFFBEE3A0),
    listOf(0xFF3B0F2E, 0xFFB8336A, 0xFFFFB37A), listOf(0xFF101820, 0xFF2C5364, 0xFF7FD1E8),
    listOf(0xFF2B1A0E, 0xFFA0522D, 0xFFFFD580), listOf(0xFF14142B, 0xFF3A2E8C, 0xFF9D8CFF),
    listOf(0xFF0B2E1F, 0xFF3E7C59, 0xFFE4D96F), listOf(0xFF2A0E0E, 0xFF8C1C13, 0xFFFF6B4A),
    listOf(0xFF081A2E, 0xFF0F4C81, 0xFF52B6FF), listOf(0xFF231433, 0xFF6B2D5C, 0xFFF0A6CA),
).map { p -> p.map { Color(it) } }

/** Gleicher Hash wie artwork.dart (_hash). */
fun artHash(s: String): Int {
    var h = 0
    for (c in s) h = 0x1fffffff and (h * 31 + c.code)
    return h
}

fun paletteFor(seed: String): List<Color> = palettes[artHash(seed) % palettes.size]

private val qualityWords = Regex("\\b(HD|FHD|UHD|4K|TV)\\b")
private val spaces = Regex("\\s+")

fun monogramOf(name: String): String {
    val words = qualityWords.replace(name, "").trim().split(spaces).filter { it.isNotEmpty() }
    val s = when {
        words.size >= 2 -> "${words[0][0]}${words[1][0]}"
        words.isEmpty() -> "?"
        else -> words[0].take(2)
    }
    return s.uppercase()
}

/**
 * Sender-Logo (Seitenverhältnis 1,4 : 1); ohne Logo ein Monogramm in
 * Senderfarbe. Bilder werden nur in Anzeigegröße dekodiert.
 */
@Composable
fun ChannelLogo(name: String, url: String?, modifier: Modifier = Modifier, height: Dp = 20.dp) {
    val width = height * 1.4f
    val shape = RoundedCornerShape(height * 0.22f)
    val web = UrlPolicy.image(url)
    if (web == null) {
        Monogram(name, modifier.size(width, height).clip(shape), height)
        return
    }
    val ctx = LocalContext.current
    val px = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
    val req = remember(web, px) {
        ImageRequest.Builder(ctx).data(web).size(px.first, px.second).crossfade(false).build()
    }
    Box(modifier.size(width, height).clip(shape).background(AppColors.surface3).padding(height * 0.12f)) {
        AsyncImage(model = req, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.matchParentSize())
    }
}

@Composable
private fun Monogram(name: String, modifier: Modifier, height: Dp) {
    val p = remember(name) { paletteFor(name) }
    val text = remember(name) { monogramOf(name) }
    Box(modifier.background(Brush.linearGradient(listOf(p[1], p[0]))), contentAlignment = Alignment.Center) {
        Text(text, color = Color.White, fontFamily = Inter, fontWeight = FontWeight.ExtraBold, fontSize = (height.value * 0.38f).sp, maxLines = 1)
    }
}

/** Generierte Grafik (Platzhalter für Karten ohne Bild), wie GeneratedArt im TV-Modus. */
fun generatedArt(seed: String): Brush {
    val p = paletteFor(seed)
    val h = artHash(seed)
    val ax = ((h % 100) / 100f) * 0.8f + 0.1f
    val ay = (((h / 100) % 100) / 100f) * 0.6f + 0.05f
    return object : androidx.compose.ui.graphics.ShaderBrush() {
        override fun createShader(size: Size): androidx.compose.ui.graphics.Shader =
            androidx.compose.ui.graphics.RadialGradientShader(
                center = Offset(size.width * ax, size.height * ay),
                radius = maxOf(size.width, size.height) * 0.9f,
                colors = listOf(lerp(p[1], p[2], 0.7f), lerp(p[1], p[2], 0.28f), lerp(p[0], p[1], 0.6f), lerp(p[0], p[1], 0.8f)),
                colorStops = listOf(0f, 0.25f, 0.7f, 1f),
            )
    }
}

private fun lerp(a: Color, b: Color, f: Float) = androidx.compose.ui.graphics.lerp(a, b, f)

// ---------------------------------------------------------------- Abzeichen

@Composable
fun LiveBadge(text: String, modifier: Modifier = Modifier) {
    Box(modifier.clip(RoundedCornerShape(3.dp)).background(AppColors.live).padding(horizontal = 4.dp, vertical = 1.dp)) {
        Text(text, color = Color.White, fontFamily = Inter, fontWeight = FontWeight.ExtraBold, fontSize = 7.sp, letterSpacing = 0.6.sp)
    }
}

/** Anzahl Varianten (HD/FHD/4K …) mit Ebenen-Symbol. */
@Composable
fun VariantBadge(count: Int, modifier: Modifier = Modifier) {
    Row(
        modifier.clip(RoundedCornerShape(4.dp)).background(AppColors.surface3).padding(horizontal = 3.dp, vertical = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(Icons.Rounded.Layers, null, tint = AppColors.textDim, modifier = Modifier.size(8.dp))
        Text("$count", color = AppColors.textDim, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 7.sp)
    }
}

@Composable
fun FavStar(modifier: Modifier = Modifier, size: Dp = 9.dp) =
    Icon(Icons.Rounded.Star, null, tint = AppColors.gold, modifier = modifier.size(size))

@Composable
fun LockIcon(modifier: Modifier = Modifier, size: Dp = 9.dp) =
    Icon(Icons.Rounded.Lock, null, tint = AppColors.textDim, modifier = modifier.size(size))

@Composable
fun SmallIcon(icon: ImageVector, tint: Color = AppColors.textDim, size: Dp = 10.dp, modifier: Modifier = Modifier) =
    Icon(icon, null, tint = tint, modifier = modifier.size(size))

/** Schriftzug „Jason Stream“ mit Signal-Punkt (Wordmark aus app.dart). */
@Composable
fun Wordmark(size: Dp = 10.dp, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(size * 1.25f).clip(RoundedCornerShape(size * 0.34f))
                .background(Brush.linearGradient(listOf(Color(0xFFFF9A5C), Color(0xFFFF4D5E)))),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Rounded.PlayArrow, null, tint = Color.White, modifier = Modifier.size(size)) }
        androidx.compose.foundation.layout.Spacer(Modifier.size(size * 0.45f))
        val fs = size.value.sp
        Text("Jason", fontFamily = InterDisplay, fontWeight = FontWeight.ExtraBold, fontSize = fs, color = AppColors.text, letterSpacing = (-0.04f * size.value).sp)
        Text("Stream", fontFamily = InterDisplay, fontWeight = FontWeight.SemiBold, fontSize = fs, color = AppColors.textDim, letterSpacing = (-0.04f * size.value).sp)
    }
}

/** Kicker-Zeile in Akzentfarbe („JETZT LIVE · RTL HD“). */
@Composable
fun Kicker(text: String, modifier: Modifier = Modifier, color: Color = LocalAccent.current.color) {
    Text(
        text.uppercase(), modifier = modifier, color = color, fontFamily = Inter, fontWeight = FontWeight.Bold,
        fontSize = 7.5.sp, letterSpacing = 1.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** Leerer Zustand mit Titel und Text. */
@Composable
fun EmptyHint(title: String, text: String? = null, modifier: Modifier = Modifier) {
    androidx.compose.foundation.layout.Column(modifier.padding(24.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        if (text != null) Text(text, color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, modifier = Modifier.padding(top = 4.dp))
    }
}
