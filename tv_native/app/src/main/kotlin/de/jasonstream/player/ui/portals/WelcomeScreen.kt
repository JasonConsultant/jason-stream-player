package de.jasonstream.player.ui.portals

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Science
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import de.jasonstream.core.R
import de.jasonstream.player.BuildConfig
import de.jasonstream.player.R as AppR
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.state.Overlay
import de.jasonstream.player.ui.common.Wordmark
import de.jasonstream.player.ui.dialogs.DialogButton
import de.jasonstream.player.ui.requestSoon
import de.jasonstream.player.ui.theme.AppColors
import de.jasonstream.player.ui.theme.Inter
import de.jasonstream.player.ui.theme.LocalAccent
import de.jasonstream.player.ui.theme.Type

/** Erster Start ohne Portal (Port von welcome_screen.dart). */
@Composable
fun WelcomeScreen(vm: AppViewModel, testBuild: Boolean = BuildConfig.TEST_BUILD) {
    val accent = LocalAccent.current.color
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { first.requestSoon() }
    Box(Modifier.fillMaxSize().background(AppColors.bg), contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 520.dp).padding(32.dp)) {
            Wordmark(14.dp)
            Spacer(Modifier.height(18.dp))
            Text(stringResource(R.string.welcome), style = Type.hero)
            Text(stringResource(R.string.liveTvTv), color = AppColors.textDim, fontFamily = Inter, fontSize = 11.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 6.dp))
            if (testBuild) {
                Row(
                    Modifier.padding(top = 14.dp).clip(RoundedCornerShape(10.dp)).background(AppColors.gold.copy(alpha = 0.10f))
                        .border(1.dp, AppColors.gold.copy(alpha = 0.4f), RoundedCornerShape(10.dp)).padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.Science, null, tint = AppColors.gold, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(9.dp))
                    Column {
                        Text(stringResource(AppR.string.tv_testBuildHint), color = AppColors.text, fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 10.sp)
                        Text(stringResource(AppR.string.tv_testBuildDetail), color = AppColors.textDim, fontFamily = Inter, fontSize = 8.5.sp)
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val w = Modifier.widthIn(min = 260.dp)
                DialogButton(stringResource(R.string.addPortal), accent, primary = true, w.focusRequester(first)) {
                    vm.pushOverlay(Overlay.EditPortal(null))
                }
                DialogButton(stringResource(R.string.setUpPhone), accent, primary = false, w) { vm.pushOverlay(Overlay.Pair) }
                DialogButton(stringResource(R.string.tryDemo), accent, primary = false, w) { vm.addDemoPortal() }
            }
            Text(stringResource(R.string.jasonStreamPlayer), color = AppColors.textFaint, fontFamily = Inter, fontSize = 8.sp, lineHeight = 12.sp, modifier = Modifier.padding(top = 18.dp))
        }
    }
}
