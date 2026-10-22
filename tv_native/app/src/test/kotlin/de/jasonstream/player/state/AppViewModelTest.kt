package de.jasonstream.player.state

import de.jasonstream.core.model.Portal
import de.jasonstream.player.logic.DemoData
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.player.logic.RawLive
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModelTest {
    @Before fun setUp() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    private suspend fun until(cond: () -> Boolean) = withTimeout(5000) { while (!cond()) delay(10) }

    private fun vm(env: TestEnv = TestEnv()): AppViewModel = runBlocking {
        val vm = AppViewModel(env, io = Dispatchers.Default, compute = Dispatchers.Default, autoStart = false)
        vm.attach(env.storage)
        vm.setDataForPreview(Portal.demo, RawLive(DemoData.categories, DemoData.channels), DemoData.epg(), current = "demo_6")
        vm
    }

    @Test fun dataFromMigratedStorage() {
        val vm = vm()
        val s = vm.live.value
        assertEquals(6, s.favoriteChannels.size)
        assertEquals(listOf("demo_16", "demo_0", "demo_2", "demo_6", "demo_20", "demo_9"), s.recentChannels.map { it.id })
        assertTrue(s.groups.any { it.id == "my_fussball" && it.count == 3 })
        assertEquals("demo_6", vm.current.value?.id)
        assertEquals(listOf("Tatort", "Liga Live", "Nachrichten"), vm.recentSearches.value)
    }

    @Test fun favoriteToggleRebuildsList() = runBlocking {
        val vm = vm()
        val c = vm.live.value.byId.getValue("demo_3")
        vm.toggleFavorite(c, "added", "removed")
        until { vm.live.value.isFavorite(c) }
        assertEquals("added", vm.message.value?.text)
        assertEquals(7, vm.live.value.channelsOf(GroupIds.FAV).size)
    }

    @Test fun lockedChannelNeedsPin() = runBlocking {
        val env = TestEnv()
        env.storage.setPin("1234")
        val vm = vm(env)
        val locked = vm.live.value.byId.getValue("demo_13")
        vm.play(locked, vm.live.value.channels, "PIN")
        until { vm.pin.value != null }
        assertNull(vm.request.value)
        val req = vm.pin.value!!
        assertTrue(vm.verifyPin("0000") is de.jasonstream.core.storage.Storage.PinResult.Wrong)
        assertEquals(de.jasonstream.core.storage.Storage.PinResult.Ok, vm.verifyPin("1234"))
        req.result.complete(true)
        until { vm.request.value != null }
        assertEquals("demo_13", vm.request.value!!.channels[vm.request.value!!.index].id)
        assertEquals(Tab.Live, vm.shell.value.tab)
        assertEquals(Zone.Content, vm.shell.value.zone)
        assertFalse(vm.liveOverlayOnEnter.value) // über „Ansehen“: nur Video
    }

    @Test fun guestModeWritesNoHistory() = runBlocking {
        val env = TestEnv()
        env.storage.setFlag("guest", true)
        val vm = vm(env)
        assertTrue(vm.live.value.recentChannels.isEmpty())
        assertTrue(vm.recentSearches.value.isEmpty()) // Gastmodus: nichts anzeigen …
        vm.addRecentSearch("Krimi")
        assertFalse(env.storage.option("recentsearch___demo", "").contains("Krimi")) // … und nichts speichern
        // Favoriten im Gastmodus unverändert.
        vm.toggleFavorite(vm.live.value.byId.getValue("demo_3"), "a", "r")
        assertFalse("demo_3" in env.storage.favorites(Portal.demo.id))
    }

    @Test fun backFromStartArmsExit() {
        val vm = vm()
        vm.setShell(de.jasonstream.player.logic.ShellState(Tab.Start, Zone.Menu))
        assertFalse(vm.back("hint"))
        assertEquals("hint", vm.message.value?.text)
        assertTrue(vm.back("hint"))
    }

    @Test fun groupMembershipAndVariantChoice() = runBlocking {
        val vm = vm()
        val c = vm.live.value.byId.getValue("demo_10")
        vm.toggleInGroup(c, "my_fussball")
        until { vm.live.value.channelsOf("my_fussball").any { it.id == "demo_10" } }
        val id = vm.createGroup("Kinder", vm.live.value.byId.getValue("demo_23"))
        assertNotNull(id)
        until { vm.live.value.groups.any { it.id == id && it.count == 1 } }
    }
}
