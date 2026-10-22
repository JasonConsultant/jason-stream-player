package de.jasonstream.player

import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import de.jasonstream.core.R as CoreR
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.player.state.AppPlayerDeps
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.ui.AppRoot
import de.jasonstream.player.ui.PlayerHost
import de.jasonstream.player.ui.dialogs.OptionItem
import de.jasonstream.player.ui.dialogs.OptionsDialog
import de.jasonstream.player.update.Integrity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

class MainActivity : ComponentActivity() {
    /** Ein ExoPlayer für Live TV und Mini-Video (wird bei ON_STOP vom Player freigegeben). */
    private val engine by lazy { PlayerEngine(this) }

    /** App-Sprache (Einstellung „set_applang“, wie die Flutter-App). */
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(localized(base))
    }

    private fun localized(base: Context): Context {
        val prefs = base.getSharedPreferences(AppContainer.PREFS_FILE, Context.MODE_PRIVATE)
        val choice = runCatching { prefs.getString("set_applang", null) }.getOrNull() ?: BuildConfig.DEFAULT_LANG
        val lang = when (choice) {
            "de", "en", "tr" -> choice
            else -> Locale.getDefault().language.let { if (it in setOf("de", "en", "tr")) it else "en" }
        }
        val cfg = Configuration(base.resources.configuration)
        cfg.setLocale(Locale.forLanguageTag(lang))
        return base.createConfigurationContext(cfg)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as JasonApp).container
        setContent {
            val vm: AppViewModel = viewModel { AppViewModel(container) }
            val pinReason = stringResource(CoreR.string.enterPin)
            val host = remember { PlayerHost(engine, AppPlayerDeps(vm) { pinReason }) }
            AppRoot(vm, host, onExit = { finish() })
            IntegrityGuard()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing) engine.release()
    }

    /** Release-Build: veränderte Kopie → nur Beenden (wie app_guard.dart). */
    @Composable
    private fun IntegrityGuard() {
        // Test-Build: andere App-ID, Prüfung aus (siehe app/build.gradle.kts „tvtest“).
        if (BuildConfig.DEBUG || BuildConfig.TEST_BUILD) return
        var tampered by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) {
            tampered = !withContext(Dispatchers.IO) { Integrity.check(this@MainActivity) }.signatureOk
        }
        if (tampered) {
            OptionsDialog(
                stringResource(CoreR.string.tamperedTitle),
                listOf(OptionItem(stringResource(CoreR.string.quit)) { finish() }),
                onDismiss = { finish() },
                subtitle = stringResource(CoreR.string.tamperedBody),
            )
        }
    }
}
