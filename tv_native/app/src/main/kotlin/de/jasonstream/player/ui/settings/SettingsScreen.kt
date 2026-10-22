package de.jasonstream.player.ui.settings

import android.app.Activity
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Audiotrack
import androidx.compose.material.icons.rounded.CloudSync
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.PersonOutline
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.ui.AppPalette
import de.jasonstream.player.R as AppR
import de.jasonstream.player.logic.UpdateInfo
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.LocalShellFocus
import de.jasonstream.player.ui.common.Wordmark
import de.jasonstream.player.ui.common.focusRing
import de.jasonstream.player.ui.common.tvClick
import de.jasonstream.player.ui.dialogs.OptionItem
import de.jasonstream.player.ui.dialogs.OptionsDialog
import de.jasonstream.player.update.Updater
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Auswahl-Werte wie in der Flutter-App (gleiche Speicherwerte). */
object SettingValues {
    val langs = listOf("system", "de", "en", "tr")
    val trackLangs = listOf("auto", "off", "de", "en", "tr", "fr", "es", "it", "pl", "ru", "ar", "sq", "hr", "ku")
    val trackLangNames = mapOf(
        "de" to "Deutsch", "en" to "English", "tr" to "Türkçe", "fr" to "Français", "es" to "Español",
        "it" to "Italiano", "pl" to "Polski", "ru" to "Русский", "ar" to "العربية", "sq" to "Shqip",
        "hr" to "Hrvatski / Srpski / Bosanski", "ku" to "Kurdî",
    )
    val subSizes = listOf("klein", "normal", "gross", "sehrgross")
    val subColors = listOf("weiss", "gelb", "cyan")
    val buffers = listOf("klein", "normal", "gross")
    val liveBuffers = listOf("0", "5", "10", "30", "60")
}

private sealed interface Dlg {
    data object Portals : Dlg
    data object Epg : Dlg
    data object Lang : Dlg
    data object Accent : Dlg
    data object SubStyle : Dlg
    data class Pick(val key: String, val title: String, val values: List<Pair<String, String>>, val fallback: String) : Dlg
    data class Update(val info: UpdateInfo) : Dlg
}

/** Einstellungen (Entwurf B: schlichte Liste mit Abschnitten). */
@Composable
fun SettingsScreen(vm: AppViewModel) {
    val portals by vm.portals.collectAsStateWithLifecycle()
    val portal by vm.portal.collectAsStateWithLifecycle()
    val accentKey by vm.accent.collectAsStateWithLifecycle()
    val shell = LocalShellFocus.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var dlg by remember { mutableStateOf<Dlg?>(null) }
    var tick by remember { mutableIntStateOf(0) } // nach Änderungen neu lesen
    var updating by remember { mutableStateOf<Int?>(null) }

    fun opt(key: String, fallback: String) = tick.let { vm.option(key, fallback) }
    fun flag(key: String, fallback: Boolean) = tick.let { vm.flag(key, fallback) }

    val sysLabel = stringResource(R.string.system)
    fun langName(l: String) = when (l) { "de" -> "Deutsch"; "en" -> "English"; "tr" -> "Türkçe"; else -> sysLabel }
    val autoLabel = stringResource(R.string.automatic)
    val offLabel = stringResource(R.string.off)
    fun trackName(l: String) = when (l) { "auto" -> autoLabel; "off" -> offLabel; else -> SettingValues.trackLangNames[l] ?: l }
    val accentNames = mapOf(
        "orange" to stringResource(R.string.accentOrange), "blau" to stringResource(R.string.accentBlue),
        "gruen" to stringResource(R.string.accentGreen), "lila" to stringResource(R.string.accentPurple),
        "rot" to stringResource(R.string.accentRed), "tuerkis" to stringResource(R.string.accentTeal),
    )
    val sizeNames = mapOf(
        "klein" to stringResource(R.string.small), "normal" to stringResource(R.string.normal),
        "gross" to stringResource(R.string.large), "sehrgross" to stringResource(R.string.subVeryLarge),
    )
    val colorNames = mapOf("weiss" to stringResource(R.string.subWhite), "gelb" to stringResource(R.string.subYellow), "cyan" to stringResource(R.string.subCyan))
    val upToDate = stringResource(R.string.upToDate)
    val busy = stringResource(R.string.updateServerBusy)
    val failed = stringResource(R.string.updateCheckFailed)
    val allowUnknown = stringResource(R.string.allowUnknownSources)

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        contentPadding = PaddingValues(top = 8.dp, bottom = 30.dp),
    ) {
        item { Section(stringResource(R.string.portal)) }
        item {
            Entry(
                Icons.Rounded.Dns, stringResource(R.string.portals),
                portal?.let { "${it.name} · ${portalTypeName(it.type)}" } ?: "–",
                Modifier.focusRequester(shell.content).focusProperties { up = shell.menu },
            ) { dlg = Dlg.Portals }
        }
        item {
            val portalEpg = stringResource(R.string.epgProvider)
            Entry(Icons.Rounded.Schedule, stringResource(R.string.epgSources), portal?.epgSources?.joinToString(" · ") { if (it == "portal") portalEpg else it.substringAfter("://").substringBefore('/') }) { dlg = Dlg.Epg }
        }
        item { Entry(Icons.Rounded.CloudSync, stringResource(R.string.reloadChannelsEpg), stringResource(R.string.fetchesFreshLists)) { vm.reload() } }

        item { Section(stringResource(R.string.appearanceSection)) }
        item { Entry(Icons.Rounded.Language, stringResource(R.string.appLanguage), langName(opt("applang", defaultLang()))) { dlg = Dlg.Lang } }
        item {
            val live = opt("starttab", "home") == "live"
            Entry(Icons.Rounded.Tv, stringResource(R.string.showOnOpen), if (live) stringResource(R.string.liveTv) else stringResource(R.string.navStart)) {
                vm.setOption("starttab", if (live) "home" else "live"); tick++
            }
        }
        item {
            Entry(Icons.Rounded.Palette, stringResource(R.string.accentColor), accentNames[accentKey] ?: accentKey, trailingColor = AppColors.accent(accentKey)) { dlg = Dlg.Accent }
        }

        item { Section(stringResource(R.string.playback)) }
        item {
            Entry(Icons.Rounded.Audiotrack, stringResource(R.string.preferredAudioLanguage), trackName(opt("alang", "auto"))) {
                dlg = Dlg.Pick("alang", "", SettingValues.trackLangs.filter { it != "off" }.map { it to trackName(it) }, "auto")
            }
        }
        item {
            Entry(Icons.Rounded.Subtitles, stringResource(R.string.subtitles), trackName(opt("slang", "auto"))) {
                dlg = Dlg.Pick("slang", "", SettingValues.trackLangs.map { it to trackName(it) }, "auto")
            }
        }
        item {
            Entry(Icons.Rounded.Subtitles, stringResource(R.string.subStyle), listOf(sizeNames[opt("sub_size", "normal")], colorNames[opt("sub_color", "weiss")]).joinToString(" · ")) { dlg = Dlg.SubStyle }
        }
        item {
            Entry(Icons.Rounded.Memory, stringResource(R.string.buffer), sizeNames[opt("buffer", "normal")] ?: "") {
                dlg = Dlg.Pick("buffer", "", SettingValues.buffers.map { it to (sizeNames[it] ?: it) }, "normal")
            }
        }
        item {
            val v = opt("livebuffer", "10")
            Entry(Icons.Rounded.Tv, stringResource(R.string.liveBuffer), if (v == "0") offLabel else stringResource(R.string.minutesN, v)) {
                dlg = Dlg.Pick("livebuffer", "", SettingValues.liveBuffers.map { it to (if (it == "0") offLabel else "$it min") }, "10")
            }
        }
        item {
            val direct = flag("tunnel", false)
            Entry(Icons.Rounded.Tv, stringResource(R.string.videoOutput), stringResource(if (direct) R.string.videoOutputDirect else R.string.videoOutputCompat)) {
                vm.setFlag("tunnel", !direct); tick++
            }
        }
        item { Toggle(stringResource(R.string.afrTitle), stringResource(R.string.afrSubtitle), flag("afr", false)) { vm.setFlag("afr", it); tick++ } }
        item { Toggle(stringResource(R.string.audioPassthrough), stringResource(R.string.audioPassthroughHint), flag("passthrough", false)) { vm.setFlag("passthrough", it); tick++ } }
        item { Toggle(stringResource(R.string.nextEpisodeAuto), stringResource(R.string.nextEpisodeAutoHint), flag("autonext", true)) { vm.setFlag("autonext", it); tick++ } }

        item { Section(stringResource(R.string.channelsUpper)) }
        item { Toggle(stringResource(R.string.mergeVariants), stringResource(R.string.mergeVariantsHint), flag("mergevariants", true), Icons.Rounded.Layers) { vm.setFlag("mergevariants", it); tick++ } }
        item { Toggle(stringResource(R.string.guestMode), stringResource(R.string.guestModeSubtitle), flag("guest", false), Icons.Rounded.PersonOutline) { vm.setFlag("guest", it); tick++ } }

        item { Section(stringResource(R.string.about)) }
        item {
            Column(Modifier.padding(start = 10.dp, top = 4.dp, bottom = 8.dp)) {
                Wordmark(12.dp)
                Text(stringResource(AppR.string.tv_version, vm.versionName), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, modifier = Modifier.padding(top = 4.dp))
                Text(stringResource(R.string.android10Android), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp)
            }
        }
        item {
            val u = updating
            Entry(
                Icons.Rounded.SystemUpdate, stringResource(R.string.checkUpdates),
                if (u != null) stringResource(AppR.string.tv_downloading, "$u") else stringResource(R.string.checkUpdatesHint),
            ) {
                scope.launch {
                    when (val r = withContext(Dispatchers.IO) { Updater.check(ctx) }) {
                        Updater.Check.UpToDate -> vm.toast(upToDate)
                        Updater.Check.Busy -> vm.toast(busy)
                        is Updater.Check.Failed -> vm.toast(String.format(failed, r.message))
                        is Updater.Check.Available -> dlg = Dlg.Update(r.info)
                    }
                }
            }
        }
        item { Entry(Icons.Rounded.Info, stringResource(R.string.loginDetailsEncrypted), stringResource(R.string.androidKeystoreNot)) { } }
    }

    when (val d = dlg) {
        null -> Unit
        Dlg.Portals -> OptionsDialog(
            stringResource(R.string.portals),
            portals.map { p -> OptionItem(p.name, Icons.Rounded.Dns, checked = p.id == portal?.id, detail = portalTypeName(p.type)) { vm.switchPortal(p) } },
            onDismiss = { dlg = null },
            subtitle = stringResource(R.string.chooseAnotherPortal),
            initialIndex = portals.indexOfFirst { it.id == portal?.id }.coerceAtLeast(0),
        )
        Dlg.Epg -> OptionsDialog(
            stringResource(R.string.epgSources),
            (portal?.epgSources ?: emptyList()).map { s -> OptionItem(if (s == "portal") stringResource(R.string.epgFromPortal) else s, Icons.Rounded.Schedule) {} },
            onDismiss = { dlg = null },
            subtitle = stringResource(AppR.string.tv_readOnly),
        )
        Dlg.Lang -> {
            val cur = opt("applang", defaultLang())
            OptionsDialog(
                stringResource(R.string.appLanguage),
                SettingValues.langs.map { l -> OptionItem(langName(l), Icons.Rounded.Language, checked = l == cur) {
                    if (l != cur) {
                        vm.setOption("applang", l)
                        (ctx as? Activity)?.recreate()
                    }
                } },
                onDismiss = { dlg = null },
                subtitle = stringResource(R.string.languageUserInterface),
                initialIndex = SettingValues.langs.indexOf(cur).coerceAtLeast(0),
            )
        }
        Dlg.Accent -> OptionsDialog(
            stringResource(R.string.accentColor),
            AppPalette.accentPresets.keys.map { k -> OptionItem(accentNames[k] ?: k, Icons.Rounded.Palette, checked = k == accentKey) { vm.setOption("accent", k) } },
            onDismiss = { dlg = null },
            initialIndex = AppPalette.accentPresets.keys.indexOf(accentKey).coerceAtLeast(0),
        )
        Dlg.SubStyle -> {
            val size = opt("sub_size", "normal")
            val color = opt("sub_color", "weiss")
            val box = opt("sub_bg", "none") == "box"
            val outline = opt("sub_outline", "on") != "off"
            OptionsDialog(
                stringResource(R.string.subStyle),
                listOf(
                    OptionItem("${stringResource(R.string.subSize)}: ${sizeNames[size]}", Icons.Rounded.Subtitles) {
                        vm.setOption("sub_size", SettingValues.subSizes[(SettingValues.subSizes.indexOf(size) + 1) % SettingValues.subSizes.size]); tick++
                    },
                    OptionItem("${stringResource(R.string.subColor)}: ${colorNames[color]}", Icons.Rounded.Palette) {
                        vm.setOption("sub_color", SettingValues.subColors[(SettingValues.subColors.indexOf(color) + 1) % SettingValues.subColors.size]); tick++
                    },
                    OptionItem(stringResource(R.string.subBox), null, checked = box, detail = stringResource(R.string.subBoxHint)) {
                        vm.setOption("sub_bg", if (box) "none" else "box"); tick++
                    },
                    OptionItem(stringResource(R.string.subOutline), null, checked = outline) {
                        vm.setOption("sub_outline", if (outline) "off" else "on"); tick++
                    },
                ),
                onDismiss = { dlg = null },
                subtitle = stringResource(R.string.subStyleHint),
                closeOnClick = false,
            )
        }
        is Dlg.Pick -> {
            val cur = opt(d.key, d.fallback)
            OptionsDialog(
                d.title.ifEmpty { d.values.firstOrNull { it.first == cur }?.second ?: "" },
                d.values.map { (k, label) -> OptionItem(label, null, checked = k == cur) { vm.setOption(d.key, k); tick++ } },
                onDismiss = { dlg = null },
                initialIndex = d.values.indexOfFirst { it.first == cur }.coerceAtLeast(0),
            )
        }
        is Dlg.Update -> OptionsDialog(
            stringResource(R.string.versionAvailable, d.info.version),
            listOf(OptionItem(stringResource(R.string.install), Icons.Rounded.SystemUpdate, detail = stringResource(R.string.updateKeepsData)) {
                if (!Updater.canInstall(ctx)) {
                    vm.toast(allowUnknown)
                    Updater.requestInstallPermission(ctx)
                } else scope.launch {
                    updating = 0
                    val f = runCatching { withContext(Dispatchers.IO) { Updater.download(ctx, d.info) { p -> updating = p } } }
                    updating = null
                    f.onSuccess { Updater.install(ctx, it) }.onFailure { vm.toast(String.format(failed, it.message ?: "?")) }
                }
            }),
            onDismiss = { dlg = null },
            subtitle = d.info.notes.take(300).ifEmpty { null },
        )
    }
}

private fun defaultLang() = de.jasonstream.player.BuildConfig.DEFAULT_LANG

@Composable
private fun portalTypeName(t: PortalType) = when (t) {
    PortalType.xtream -> "Xtream"
    PortalType.m3u -> stringResource(R.string.m3uPlaylist)
    PortalType.stalker -> stringResource(R.string.macPortal)
    PortalType.demo -> stringResource(R.string.demo)
}

@Composable
private fun Section(title: String) {
    Text(
        title.uppercase(), color = AppColors.textFaint, fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 7.5.sp,
        letterSpacing = 1.5.sp, modifier = Modifier.padding(start = 10.dp, top = 14.dp, bottom = 4.dp),
    )
}

@Composable
private fun Entry(
    icon: ImageVector,
    title: String,
    value: String?,
    modifier: Modifier = Modifier,
    trailingColor: Color? = null,
    onClick: () -> Unit,
) {
    val accent = LocalAccent.current.color
    Row(
        modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = AppColors.textDim, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp, maxLines = 1)
            if (!value.isNullOrEmpty()) Text(value, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (trailingColor != null) Box(Modifier.size(12.dp).clip(CircleShape).background(trailingColor))
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = AppColors.textFaint, modifier = Modifier.size(13.dp))
    }
}

@Composable
private fun Toggle(title: String, subtitle: String, on: Boolean, icon: ImageVector? = null, onChange: (Boolean) -> Unit) {
    val accent = LocalAccent.current.color
    Row(
        Modifier.widthIn(max = 600.dp).fillMaxWidth()
            .focusRing(accent, focusedBg = AppColors.rowFocus, radius = 8.dp)
            .tvClick { onChange(!on) }
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, tint = AppColors.textDim, modifier = Modifier.size(13.dp)); Spacer(Modifier.width(10.dp)) } else Spacer(Modifier.width(23.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.5.sp, maxLines = 1)
            Text(subtitle, color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        // Schalter (nur Anzeige – der ganze Eintrag schaltet).
        Box(Modifier.size(24.dp, 13.dp).clip(CircleShape).background(if (on) accent else AppColors.surface3), contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart) {
            Box(Modifier.padding(2.dp).size(9.dp).clip(CircleShape).background(Color.White))
        }
    }
}
