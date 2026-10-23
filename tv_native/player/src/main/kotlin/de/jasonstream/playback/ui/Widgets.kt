package de.jasonstream.playback.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons as MI
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.FormatListBulleted
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Circle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Dialpad
import androidx.compose.material.icons.rounded.FiberManualRecord
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.GppBad
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.KeyOff
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PersonOutline
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PublicOff
import androidx.compose.material.icons.rounded.RadioButtonChecked
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.SignalWifiBad
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.TimerOff
import androidx.compose.material.icons.rounded.TvOff
import androidx.compose.material.icons.rounded.CheckBox
import androidx.compose.material.icons.rounded.CheckBoxOutlineBlank
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.platform.testTag
import de.jasonstream.playback.nav.dpadList
import de.jasonstream.playback.nav.rememberDpadList
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import coil3.request.crossfade
import de.jasonstream.core.security.UrlPolicy

/** Benutzte Symbole (Material Rounded, wie die Flutter-App). */
internal object Icons {
    val back = MI.AutoMirrored.Rounded.ArrowBack
    val list = MI.AutoMirrored.Rounded.FormatListBulleted
    val aspect = MI.Rounded.AspectRatio
    val bedtime = MI.Rounded.Bedtime
    val chevronLeft = MI.Rounded.ChevronLeft
    val chevronRight = MI.Rounded.ChevronRight
    val circle = MI.Rounded.Circle
    val close = MI.Rounded.Close
    val dialpad = MI.Rounded.Dialpad
    val record = MI.Rounded.FiberManualRecord
    val forward10 = MI.Rounded.Forward10
    val replay10 = MI.Rounded.Replay10
    val gppBad = MI.Rounded.GppBad
    val graphicEq = MI.Rounded.GraphicEq
    val history = MI.Rounded.History
    val info = MI.Rounded.Info
    val keyOff = MI.Rounded.KeyOff
    val up = MI.Rounded.KeyboardArrowUp
    val down = MI.Rounded.KeyboardArrowDown
    val layers = MI.Rounded.Layers
    val pause = MI.Rounded.Pause
    val person = MI.Rounded.PersonOutline
    val play = MI.Rounded.PlayArrow
    val publicOff = MI.Rounded.PublicOff
    val radioOn = MI.Rounded.RadioButtonChecked
    val radioOff = MI.Rounded.RadioButtonUnchecked
    val checkOn = MI.Rounded.CheckBox
    val checkOff = MI.Rounded.CheckBoxOutlineBlank
    val refresh = MI.Rounded.Refresh
    val replay = MI.Rounded.Replay
    val restart = MI.Rounded.RestartAlt
    val wifiBad = MI.Rounded.SignalWifiBad
    val skipNext = MI.Rounded.SkipNext
    val skipPrevious = MI.Rounded.SkipPrevious
    val star = MI.Rounded.Star
    val starBorder = MI.Rounded.StarBorder
    val subtitles = MI.Rounded.Subtitles
    val swap = MI.Rounded.SwapHoriz
    val timerOff = MI.Rounded.TimerOff
    val tvOff = MI.Rounded.TvOff
}

internal fun interStyle(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = Color.White, family: FontFamily = PlayerType.Inter) =
    TextStyle(fontFamily = family, fontSize = size, fontWeight = weight, color = color)

/** Fokussierbare Fläche wie FocusableTile (Akzent-Rand 2 dp, surface3 bei Fokus, optional Vergrößerung). */
@Composable
internal fun Tile(
    onClick: () -> Unit,
    accent: Color,
    modifier: Modifier = Modifier,
    radius: Dp = 12.dp,
    selected: Boolean = false,
    scaleOnFocus: Boolean = false,
    focusRequester: FocusRequester? = null,
    content: @Composable (focused: Boolean) -> Unit,
) {
    val src = remember { MutableInteractionSource() }
    val focused by src.collectIsFocusedAsState()
    val scale by animateFloatAsState(if (scaleOnFocus && focused) 1.05f else 1f, label = "tile")
    val shape = RoundedCornerShape(radius)
    Box(
        modifier
            .scale(scale)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .clip(shape)
            .background(if (focused) C.surface3 else if (selected) C.surface2 else Color.Transparent, shape)
            .border(2.dp, if (focused) accent else Color.Transparent, shape)
            .clickable(interactionSource = src, indication = null, onClick = onClick),
    ) { content(focused) }
}

/** Runder Knopf (weiß 12 %) wie _RoundBtn. */
@Composable
internal fun RoundBtn(
    icon: ImageVector,
    accent: Color,
    onClick: () -> Unit,
    size: Dp = 44.dp,
    focusRequester: FocusRequester? = null,
    tint: Color = Color.White,
    modifier: Modifier = Modifier,
) {
    Tile(onClick, accent, modifier.size(size), radius = size, focusRequester = focusRequester) {
        Box(Modifier.size(size).background(C.white12, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(size * 0.5f))
        }
    }
}

/** Pille mit Symbol und Text (_PillBtn). */
@Composable
internal fun PillBtn(icon: ImageVector, label: String, color: Color, accent: Color, onClick: () -> Unit, filled: Boolean = false, modifier: Modifier = Modifier) {
    Tile(onClick, accent, modifier.height(44.dp), radius = 22.dp) {
        Row(
            Modifier.height(44.dp).background(if (filled) color else C.white12, RoundedCornerShape(22.dp)).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, tint = if (filled) Color.White else color, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(label, style = interStyle(14.sp, FontWeight.Bold))
        }
    }
}

/** Kleines Etikett (Tag): „LIVE“, „REPLAY“, „FHD“. */
@Composable
internal fun Tag(text: String, color: Color, filled: Boolean = false) {
    Box(
        Modifier.background(if (filled) color else color.copy(alpha = 0.14f), RoundedCornerShape(5.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(text, style = interStyle(10.sp, FontWeight.Bold, if (filled) Color.White else color).copy(letterSpacing = 0.4.sp))
    }
}

/** Dünner Fortschrittsbalken (ThinProgress). */
@Composable
internal fun ThinProgress(value: Float, accent: Color, height: Dp = 4.dp, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(height)
    Box(modifier.fillMaxWidth().height(height).clip(shape).background(Color.White.copy(alpha = 0.10f))) {
        Box(Modifier.fillMaxWidth(value.coerceIn(0f, 1f)).height(height).background(accent))
    }
}

private val palettes = listOf(
    listOf(0xFF1B2A6B, 0xFF6A3DE8, 0xFFFF7A45), listOf(0xFF0E3B43, 0xFF1F8A70, 0xFFBEE3A0),
    listOf(0xFF3B0F2E, 0xFFB8336A, 0xFFFFB37A), listOf(0xFF101820, 0xFF2C5364, 0xFF7FD1E8),
    listOf(0xFF2B1A0E, 0xFFA0522D, 0xFFFFD580), listOf(0xFF14142B, 0xFF3A2E8C, 0xFF9D8CFF),
    listOf(0xFF0B2E1F, 0xFF3E7C59, 0xFFE4D96F), listOf(0xFF2A0E0E, 0xFF8C1C13, 0xFFFF6B4A),
    listOf(0xFF081A2E, 0xFF0F4C81, 0xFF52B6FF), listOf(0xFF231433, 0xFF6B2D5C, 0xFFF0A6CA),
)

/** Gleiche Hash-Funktion wie artwork.dart (Farben je Name identisch). */
internal fun paletteFor(seed: String): List<Color> {
    var h = 0
    for (c in seed) h = 0x1fffffff and (h * 31 + c.code)
    return palettes[h % palettes.size].map { Color(it) }
}

private val qualityWords = Regex("\\b(HD|FHD|UHD|4K|TV)\\b")

/** Senderlogo bzw. Monogramm (ChannelLogo). Breite = 1,35 × Höhe. */
@Composable
internal fun ChannelLogo(name: String, url: String?, size: Dp) {
    val radius = RoundedCornerShape(size * 0.22f)
    val w = size * 1.35f
    if (UrlPolicy.image(url) == null) {
        Monogram(name, size, w, radius)
        return
    }
    // Feste Dekodiergröße: Treffer im Speicher-Cache erscheinen sofort (kein
    // „Aufploppen“ des Logos bei jedem Umschalten/Blättern der Leiste).
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val px = with(androidx.compose.ui.platform.LocalDensity.current) { w.roundToPx() to size.roundToPx() }
    val req = remember(url, px) {
        coil3.request.ImageRequest.Builder(ctx).data(url).size(px.first, px.second).crossfade(false).build()
    }
    Box(Modifier.size(w, size).background(C.surface3, radius).padding(size * 0.12f), contentAlignment = Alignment.Center) {
        AsyncImage(model = req, contentDescription = null, contentScale = ContentScale.Fit)
    }
}

@Composable
private fun Monogram(name: String, size: Dp, w: Dp, shape: RoundedCornerShape) {
    val p = paletteFor(name)
    val words = name.replace(qualityWords, "").trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    val initials = when {
        words.size >= 2 -> "${words[0][0]}${words[1][0]}"
        words.isEmpty() -> "?"
        else -> words[0].take(2)
    }
    Box(
        Modifier.size(w, size).background(Brush.linearGradient(listOf(p[1], p[0])), shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initials.uppercase(),
            style = interStyle((size.value * 0.38f).sp, FontWeight.ExtraBold).copy(letterSpacing = (-0.5).sp),
        )
    }
}

/** Kleiner Hinweis (Wiederverbinden, Zeitversatz) – _StatusPill. */
@Composable
internal fun StatusPill(text: String, accent: Color, icon: ImageVector? = null, busy: Boolean = false) {
    Row(
        Modifier.background(Color.Black.copy(alpha = 0.66f), RoundedCornerShape(20.dp)).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) Spinner(accent, 14.dp, 2.dp) else if (icon != null) Icon(icon, null, tint = C.gold, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, style = interStyle(13.5.sp, FontWeight.SemiBold))
    }
}

/** Drehender Kreis (CircularProgressIndicator). */
@Composable
internal fun Spinner(color: Color, size: Dp, stroke: Dp, progress: Float? = null) {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by transition.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(1000, easing = androidx.compose.animation.core.LinearEasing)),
        label = "angle",
    )
    androidx.compose.foundation.Canvas(Modifier.size(size)) {
        val s = stroke.toPx()
        val st = androidx.compose.ui.graphics.drawscope.Stroke(width = s, cap = androidx.compose.ui.graphics.StrokeCap.Round)
        val inset = s / 2
        val arcSize = androidx.compose.ui.geometry.Size(this.size.width - s, this.size.height - s)
        val tl = androidx.compose.ui.geometry.Offset(inset, inset)
        if (progress != null) {
            drawArc(C.line, 0f, 360f, false, tl, arcSize, style = st)
            drawArc(color, -90f, 360f * progress, false, tl, arcSize, style = st)
        } else {
            drawArc(color, angle, 270f, false, tl, arcSize, style = st)
        }
    }
}

/** Eintrag einer Auswahl (Spuren, Bildformat, Schlaf-Timer, Varianten). */
internal data class SheetItem(
    val label: String,
    val subtitle: String? = null,
    val icon: ImageVector? = null,
    val selected: Boolean = false,
    val onClick: () -> Unit,
)

internal sealed interface SheetRow {
    data class Header(val title: String, val subtitle: String? = null) : SheetRow
    data class Item(val item: SheetItem) : SheetRow
    data object Divider : SheetRow
}

/** Auswahl unten mittig (wie showModalBottomSheet, max. 560 dp). */
@Composable
internal fun OptionSheet(rows: List<SheetRow>, accent: Color, initialFocus: FocusRequester) {
    val firstSelected = rows.indexOfFirst { it is SheetRow.Item && it.item.selected }
        .takeIf { it >= 0 } ?: rows.indexOfFirst { it is SheetRow.Item }
    // ▲▼ selbst geführt (Überschriften/Trenner übersprungen): Slot = fokussierbarer Eintrag.
    val slots = remember(rows) { rows.indices.filter { rows[it] is SheetRow.Item } }
    val slotOf = remember(slots, rows.size) { IntArray(rows.size) { -1 }.also { a -> slots.forEachIndexed { s, li -> a[li] = s } } }
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val nav = rememberDpadList(listState, slots.size)
    nav.lazyIndexOf = { slots.getOrElse(it) { 0 } }
    LaunchedEffect(Unit) {
        val s0 = slotOf.getOrElse(firstSelected) { 0 }.coerceAtLeast(0)
        if (firstSelected > 2) listState.scrollToItem(firstSelected - 2)
        nav.index = s0
        repeat(6) {
            if (runCatching { nav.requester(s0).requestFocus() }.getOrDefault(false)) return@LaunchedEffect
            withFrameNanos { }
        }
    }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
        androidx.compose.foundation.lazy.LazyColumn(
            state = listState,
            modifier = Modifier
                .testTag("player_sheet")
                .dpadList(nav)
                .width(560.dp)
                .heightIn(max = 520.dp)
                .background(C.surface, RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
                .padding(vertical = 12.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp),
        ) {
            items(rows.size) { i ->
                when (val r = rows[i]) {
                    is SheetRow.Header -> Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                        Text(r.title, style = interStyle(16.sp, FontWeight.SemiBold, C.text))
                        r.subtitle?.let { Text(it, style = interStyle(14.sp, color = C.textDim)) }
                    }
                    SheetRow.Divider -> Box(Modifier.fillMaxWidth().padding(vertical = 6.dp).height(1.dp).background(C.line))
                    is SheetRow.Item -> Tile(
                        r.item.onClick, accent, Modifier.fillMaxWidth().padding(vertical = 2.dp).then(nav.item(slotOf[i])),
                        focusRequester = if (i == firstSelected) initialFocus else null,
                    ) {
                        Row(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                r.item.icon ?: if (r.item.selected) Icons.radioOn else Icons.radioOff, null,
                                tint = if (r.item.selected) accent else C.textDim, modifier = Modifier.size(22.dp),
                            )
                            Spacer(Modifier.width(16.dp))
                            Column(Modifier.weight(1f)) {
                                Text(r.item.label, style = interStyle(15.sp, FontWeight.Medium, C.text), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                r.item.subtitle?.let {
                                    Text(it, style = interStyle(13.sp, color = C.textDim), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Zentrierter Text mit Akzent-Rand (Direktwahl). */
@Composable
internal fun DigitsBox(text: String, accent: Color) {
    Box(
        Modifier.background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(14.dp))
            .border(2.dp, accent, RoundedCornerShape(14.dp))
            .padding(horizontal = 22.dp, vertical = 10.dp),
    ) {
        Text(text, style = interStyle(44.sp, FontWeight.ExtraBold, family = PlayerType.InterDisplay), textAlign = TextAlign.Center)
    }
}
