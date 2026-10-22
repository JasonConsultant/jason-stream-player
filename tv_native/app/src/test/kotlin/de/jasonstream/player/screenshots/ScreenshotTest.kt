package de.jasonstream.player.screenshots

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import de.jasonstream.core.model.Portal
import de.jasonstream.player.logic.DemoData
import de.jasonstream.player.logic.RawLive
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.state.AppViewModel
import de.jasonstream.player.state.TestEnv
import de.jasonstream.player.ui.AppRoot
import de.jasonstream.player.ui.PlayerHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.util.Calendar

/**
 * Bildschirmfotos der TV-Oberfläche mit Demo-Daten (1920×1080, xhdpi):
 * `./gradlew :app:testStandardDebugUnitTest -Pscreenshots -PscreenshotDir=…`
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class ScreenshotTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()

    /** Feste Uhrzeit (heute 21:41) – Programm und Fortschritt sehen immer gleich aus. */
    private val now: Long = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 21); set(Calendar.MINUTE, 41); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun vm(): AppViewModel {
        val env = TestEnv()
        val vm = AppViewModel(env, io = Dispatchers.Default, compute = Dispatchers.Default, autoStart = false, clock = { now })
        vm.attach(env.storage)
        runBlocking { vm.setDataForPreview(Portal.demo, RawLive(DemoData.categories, DemoData.channels), DemoData.epg(now), current = "demo_6") }
        return vm
    }

    private fun shoot(name: String, setup: (AppViewModel) -> Unit) {
        val vm = vm()
        setup(vm)
        rule.setContent { AppRoot(vm, PlayerHost(null, null), onExit = {}, fixedNow = now) }
        rule.waitForIdle()
        // Hintergrund-Arbeit (Suchindex, Sport-Zeile) abwarten.
        repeat(8) {
            rule.mainClock.advanceTimeBy(400)
            Thread.sleep(150)
            rule.waitForIdle()
        }
        // Selbst zeichnen (captureToImage wartet unter Robolectric auf ein Hardware-Bild).
        val root = rule.activity.window.decorView
        val bmp = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        root.draw(android.graphics.Canvas(bmp))
        val dir = File(System.getProperty("jsp.screenshotDir") ?: "build/screenshots").also { it.mkdirs() }
        File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun start() = shoot("1_start") { it.setShell(ShellState(Tab.Start, Zone.Content)) }

    @Test fun liveOverlay() = shoot("2_live_overlay") {
        it.lastLiveGroup = "__fav"
        it.setShell(ShellState(Tab.Live, Zone.Content))
    }

    @Test fun guide() = shoot("3_guide") { it.setShell(ShellState(Tab.Guide, Zone.Content)) }

    @Test fun search() = shoot("4_search") {
        it.pendingSearch = "sport"
        it.setShell(ShellState(Tab.Search, Zone.Content))
    }

    @Test fun settings() = shoot("5_settings") { it.setShell(ShellState(Tab.Settings, Zone.Content)) }

    @Test fun menuFocused() = shoot("6_start_menu") { it.setShell(ShellState(Tab.Start, Zone.Menu)) }
}
