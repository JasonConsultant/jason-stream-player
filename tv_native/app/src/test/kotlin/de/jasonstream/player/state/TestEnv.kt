package de.jasonstream.player.state

import de.jasonstream.core.model.MyGroup
import de.jasonstream.core.model.Portal
import de.jasonstream.core.prefs.MemoryKeyValueStore
import de.jasonstream.core.security.SecretCipher
import de.jasonstream.core.storage.Storage

/** Klartext-„Verschlüsselung“ für Tests (kein Keystore auf der JVM). */
object PlainCipher : SecretCipher {
    override fun encrypt(plain: String) = "p:$plain"
    override fun decrypt(cipher: String) = cipher.removePrefix("p:")
}

/** Speicher im Arbeitsspeicher mit Demo-Portal. */
class TestEnv(demoSetup: Boolean = true) : AppEnv {
    val prefs = MemoryKeyValueStore()
    val storage: Storage = Storage.open(prefs, PlainCipher).also { st ->
        if (demoSetup) {
            st.addPortal(Portal.demo)
            st.setActivePortal(Portal.demo.id)
            // Favoriten, Verlauf, eigene Gruppe, gesperrter Sender (wie ein echter Nutzer).
            for (id in listOf("demo_0", "demo_1", "demo_6", "demo_11", "demo_16", "demo_20")) st.toggleFavorite(Portal.demo.id, id)
            for (id in listOf("demo_9", "demo_20", "demo_6", "demo_2", "demo_0", "demo_16")) st.pushRecent(Portal.demo.id, id)
            st.setLastChannel(Portal.demo.id, "demo_6")
            st.setMyGroups(Portal.demo.id, listOf(MyGroup("my_fussball", "Fußball", listOf("demo_6", "demo_7", "demo_8"))))
            st.toggleLocked(Portal.demo.id, "demo_13")
            st.setOption("recentsearch_${Portal.demo.id}", "[\"Tatort\",\"Liga Live\",\"Nachrichten\"]")
        }
    }

    override fun openStorage(): Storage = storage
    override val versionName = "2.0.0-alpha1"
    override val packageName = "de.jasonstream.player"
}
