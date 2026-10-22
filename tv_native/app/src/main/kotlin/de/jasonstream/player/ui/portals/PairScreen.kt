package de.jasonstream.player.ui.portals

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder
import de.jasonstream.core.R
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.player.logic.FriendlyError
import de.jasonstream.player.logic.PortalForm
import de.jasonstream.player.pairing.PairError
import de.jasonstream.player.pairing.PairingException
import de.jasonstream.player.pairing.PairingResult
import de.jasonstream.player.pairing.PairingSession
import de.jasonstream.player.pairing.PairingTexts
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.dialogs.DialogButton
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.UUID

/** Texte der Handy-Seite in der App-Sprache. */
fun pairingTexts(ctx: Context): PairingTexts {
    val r = ctx.resources
    fun s(id: Int) = r.getString(id)
    return PairingTexts(
        lang = r.configuration.locales[0]?.language ?: Locale.getDefault().language,
        pageTitle = s(R.string.pairTv),
        subtitle = s(R.string.sendLoginDetails),
        loginType = s(R.string.loginType),
        m3uPlaylist = s(R.string.m3uPlaylist),
        macPortal = s(R.string.macPortal),
        name = s(R.string.name),
        optional = s(R.string.optional),
        nameHint = s(R.string.portalNameHint),
        serverUrl = s(R.string.serverUrl),
        playlistUrl = s(R.string.playlistUrl),
        portalUrl = s(R.string.portalUrl),
        username = s(R.string.username),
        password = s(R.string.password),
        macAddress = s(R.string.macAddress),
        send = s(R.string.sendTv),
        note = s(R.string.dataOnlyGoes),
        doneTitle = s(R.string.done),
        doneText = s(R.string.doneCheckTv),
        notFoundTitle = s(R.string.notFound),
        notFoundText = s(R.string.addressInvalidHas),
        notAllowedTitle = s(R.string.notAllowed),
        notAllowedText = s(R.string.requestNotSupported),
        badRequestTitle = s(R.string.invalidRequest),
        badFormatText = s(R.string.wrongDataFormat),
        tooLargeTitle = s(R.string.tooLarge),
        tooLargeText = s(R.string.inputTooLarge),
        expiredTitle = s(R.string.expired),
        expiredText = s(R.string.pairingHasAlready),
        errors = mapOf(
            PairError.UrlMissingXtream to s(R.string.pleaseEnterServer),
            PairError.UrlMissingM3u to s(R.string.pleaseEnterPlaylist),
            PairError.UrlMissingStalker to s(R.string.pleaseEnterPortal),
            PairError.UrlScheme to s(R.string.addressMustStart),
            PairError.EpgScheme to s(R.string.epgUrlMust),
            PairError.UserMissing to s(R.string.pleaseEnterUsername),
            PairError.PassMissing to s(R.string.pleaseEnterPassword),
            PairError.MacMissing to s(R.string.pleaseEnterMac),
            PairError.MacFormat to s(R.string.macAddressMust),
            PairError.Unreadable to s(R.string.inputCouldNot),
        ),
    )
}

/** Übertragene Zugangsdaten → Portal. */
fun PairingResult.toPortal(): Portal {
    val t = when (type) { "m3u" -> PortalType.m3u; "stalker" -> PortalType.stalker; else -> PortalType.xtream }
    return Portal(
        id = UUID.randomUUID().toString(),
        name = name,
        type = t,
        url = url,
        username = if (t == PortalType.stalker) mac?.let { PortalForm.normalizeMac(it) } else username,
        password = if (t == PortalType.xtream) password else null,
        epgUrl = epgUrl,
    )
}

/**
 * „Mit dem Handy einrichten“ (Port von pair_screen.dart): Der Fernseher
 * zeigt einen QR-Code, das Handy öffnet die Seite im Browser (gleiches
 * WLAN) und schickt die Zugangsdaten direkt an den Fernseher.
 */
@Composable
fun PairScreen(vm: AppViewModel) {
    val ctx = LocalContext.current
    var url by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    val retry = remember { FocusRequester() }
    val accent = LocalAccent.current.color

    LaunchedEffect(attempt) {
        url = null; error = null; status = null
        val result = CompletableDeferred<Result<PairingResult>>()
        val texts = pairingTexts(ctx)
        val session = try {
            withContext(Dispatchers.IO) { PairingSession.start(texts) { result.complete(it) } }
        } catch (e: PairingException) {
            error = ctx.getString(reasonText(e.reason)); return@LaunchedEffect
        } catch (e: Exception) {
            error = FriendlyError.of(e).resolve(ctx.resources); return@LaunchedEffect
        }
        try {
            url = session.url
            val r = result.await()
            val pr = r.getOrElse { e ->
                error = if (e is PairingException) ctx.getString(reasonText(e.reason)) else FriendlyError.of(e).resolve(ctx.resources)
                return@LaunchedEffect
            }
            url = null
            status = ctx.getString(R.string.pairingConnecting, pr.name)
            val p = pr.toPortal()
            vm.testPortal(p).onSuccess {
                vm.savePortal(p)
                vm.closeOverlays()
            }.onFailure { e ->
                status = null
                error = ctx.getString(R.string.connectionFailed, FriendlyError.of(e).resolve(ctx.resources))
            }
        } finally {
            session.cancel() // Bildschirm verlassen → Server sofort zu
        }
    }
    LaunchedEffect(error) { if (error != null) retry.requestSoon() }

    Box(Modifier.fillMaxSize().background(AppColors.bg), contentAlignment = Alignment.Center) {
        Row(Modifier.padding(horizontal = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.sendLoginFrom), style = Type.title)
                Spacer(Modifier.height(14.dp))
                val steps = listOf(R.string.phoneTvSame, R.string.openCameraApp, R.string.enterLoginDetails)
                steps.forEachIndexed { i, s ->
                    Row(Modifier.padding(bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(20.dp).clip(CircleShape).background(accent.copy(alpha = 0.2f)), contentAlignment = Alignment.Center) {
                            Text("${i + 1}", color = accent, fontFamily = Inter, fontWeight = FontWeight.ExtraBold, fontSize = 10.sp)
                        }
                        Spacer(Modifier.width(10.dp))
                        Text(stringResource(s), color = AppColors.text, fontFamily = Inter, fontSize = 11.sp)
                    }
                }
                val u = url
                if (u != null) {
                    Text(stringResource(R.string.pairingOpenInBrowser, u), color = AppColors.textDim, fontFamily = Inter, fontSize = 9.sp, lineHeight = 13.sp, modifier = Modifier.padding(top = 4.dp))
                }
                Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Lock, null, tint = AppColors.catchup, modifier = Modifier.size(11.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.dataGoesDirectly), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp)
                }
            }
            Spacer(Modifier.width(40.dp))
            Box(Modifier.width(250.dp), contentAlignment = Alignment.Center) {
                val e = error
                val st = status
                val u = url
                when {
                    e != null -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Icon(Icons.Rounded.WifiOff, null, tint = AppColors.live, modifier = Modifier.size(34.dp))
                        Text(e, color = AppColors.text, fontFamily = Inter, fontSize = 10.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(vertical = 10.dp))
                        DialogButton(stringResource(R.string.newCode), accent, primary = true, Modifier.focusRequester(retry)) { attempt++ }
                    }
                    st != null -> Text(st, color = AppColors.text, fontFamily = Inter, fontSize = 11.sp, textAlign = TextAlign.Center)
                    u != null -> QrCode(u, 210.dp)
                    else -> Text("…", color = AppColors.textDim, fontSize = 20.sp)
                }
            }
        }
    }
}

private fun reasonText(r: PairingException.Reason) = when (r) {
    PairingException.Reason.Expired -> R.string.timesUpPlease
    PairingException.Reason.Cancelled -> R.string.pairingCancelled
    PairingException.Reason.NoNetwork -> R.string.noWiFi
}

/** QR-Code (zxing-Encoder, gezeichnet ohne Bitmap), weiß mit Ruhezone. */
@Composable
fun QrCode(text: String, size: Dp, modifier: Modifier = Modifier) {
    val matrix = remember(text) {
        runCatching {
            Encoder.encode(text, ErrorCorrectionLevel.M, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")).matrix
        }.getOrNull()
    } ?: return
    Box(modifier.size(size).clip(RoundedCornerShape(12.dp)).background(Color.White).padding(12.dp)) {
        Canvas(Modifier.fillMaxSize()) {
            val n = matrix.width
            val cell = this.size.minDimension / n
            for (y in 0 until n) for (x in 0 until n) {
                if (matrix.get(x, y).toInt() == 1) {
                    drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
                }
            }
        }
    }
}
