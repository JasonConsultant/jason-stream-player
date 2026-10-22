package de.jasonstream.playback

import de.jasonstream.data.channels.VariantIndex
import de.jasonstream.data.channels.groupVariants
import de.jasonstream.playback.api.StoragePlayerDeps
import de.jasonstream.playback.logic.DigitEntry
import de.jasonstream.playback.logic.DigitResult
import de.jasonstream.playback.logic.ZapBarState
import de.jasonstream.playback.logic.wrapIndex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ZapAndDigitsTest {
    private val list = listOf(ch("a", number = 1), ch("b", number = 2), ch("c", number = 3))

    @Test fun wrapping() {
        assertEquals(2, wrapIndex(-1, 3))
        assertEquals(0, wrapIndex(3, 3))
        assertEquals(1, wrapIndex(7, 3))
        assertEquals(0, wrapIndex(5, 0))
    }

    @Test fun zapBarBrowseAndConfirm() {
        val z = ZapBarState()
        z.show(1, 3)
        assertFalse(z.isPreview(1, 3))
        assertNull(z.confirm(1, 3)) // gezeigter = laufender
        z.browse(1, current = 1, n = 3)
        assertEquals(2, z.index)
        assertTrue(z.isPreview(1, 3))
        z.browse(1, 1, 3)
        assertEquals(0, z.index) // zyklisch
        assertEquals(0, z.confirm(1, 3))
        z.hide(1)
        assertFalse(z.visible)
        // Blättern bei ausgeblendeter Leiste startet beim laufenden Sender.
        z.browse(-1, current = 1, n = 3)
        assertEquals(0, z.index)
    }

    @Test fun digitsKeepLastFour() {
        val d = DigitEntry()
        d.push(1); d.push(2); d.push(3); d.push(4)
        assertEquals("2345", d.push(5))
    }

    @Test fun commitFindsInCurrentList() {
        val d = DigitEntry()
        d.push(2)
        assertEquals(DigitResult.InList(1), d.commit(list))
        assertEquals("", d.digits)
        assertEquals(DigitResult.Empty, d.commit(list))
    }

    @Test fun commitFallsBackToAllChannels() {
        val all = list + ch("z", number = 42)
        val d = DigitEntry()
        d.push(4); d.push(2)
        val r = d.commit(list, all)
        assertEquals(DigitResult.InOther(all, 3), r)
    }

    @Test fun commitNotFound() {
        val d = DigitEntry()
        d.push(0); d.push(9); d.push(9)
        assertEquals(DigitResult.NotFound(99), d.commit(list, list))
    }

    @Test fun numberOfHiddenVariantResolvesToRepresentative() {
        val hd = ch("zdf_hd", "ZDF HD", number = 10)
        val sd = ch("zdf_sd", "ZDF SD", number = 11)
        val raw = listOf(hd, sd)
        val idx = VariantIndex.of(groupVariants(raw))
        val visible = idx.collapse(raw) // nur „ZDF HD“
        assertEquals(1, visible.size)
        val d = DigitEntry()
        d.push(1); d.push(1)
        assertEquals(DigitResult.InList(0), d.commit(visible, visible, raw, idx))
    }

    @Test fun variantPlayOrderAndChoiceStoredLikeFlutter() {
        val fhd = ch("1", "RTL FHD")
        val hd = ch("2", "RTL HD")
        val sd = ch("3", "RTL SD")
        val idx = VariantIndex.of(groupVariants(listOf(sd, hd, fhd)))
        val st = memStorage()
        val deps = object : StoragePlayerDeps(st) {
            override fun variantIndex() = idx
        }
        val g = idx.groupOf("3")!!
        assertEquals(listOf("1", "2", "3"), g.members.map { it.id }) // FHD, HD, SD
        deps.chooseVariant("p", sd)
        assertEquals(mapOf(g.key to "3"), deps.variantChoices("p"))
        assertEquals(listOf("3", "1", "2"), g.playOrder(deps.variantChoices("p")[g.key]).map { it.id })
        // Beste Variante gewählt → nichts merken.
        deps.chooseVariant("p", fhd)
        assertEquals(emptyMap<String, String>(), deps.variantChoices("p"))
        assertTrue(st.option("varpick_p", "").startsWith("{"))
    }

    @Test fun requestEchoFromAppIsNotReopened() {
        val a = de.jasonstream.playback.api.PlayRequest.live("p", list, 1)
        val echo = a.copy(title = "anders", channels = list.toList())
        assertTrue(de.jasonstream.playback.ui.PlayerController.sameTarget(a, echo))
        assertFalse(de.jasonstream.playback.ui.PlayerController.sameTarget(a, a.copy(index = 2)))
        assertFalse(de.jasonstream.playback.ui.PlayerController.sameTarget(a, a.copy(kind = de.jasonstream.playback.api.PlayRequest.Kind.VOD)))
    }

    @Test fun favoritesAndGuestMode() {
        val st = memStorage()
        val deps = StoragePlayerDeps(st)
        val c = ch("x")
        assertTrue(deps.toggleFavorite("p", c))
        assertTrue(deps.isFavorite("p", c))
        st.setFlag("guest", true)
        assertFalse(deps.toggleFavorite("p", c))
        assertTrue(deps.isFavorite("p", c))
    }
}
