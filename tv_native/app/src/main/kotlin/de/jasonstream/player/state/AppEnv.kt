package de.jasonstream.player.state

import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.storage.Storage
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import de.jasonstream.data.cache.ListCache
import de.jasonstream.player.logic.DemoData
import java.io.File

/**
 * Was die Oberfläche von der Umgebung braucht – [de.jasonstream.player.AppContainer]
 * auf dem Gerät, eine Speicher-Attrappe in Tests und Bildschirmfotos.
 */
interface AppEnv {
    /** Öffnet den Speicher (blockiert, Keystore). */
    fun openStorage(): Storage

    /** Einmalige Datenübernahme aus der Flutter-App (blockiert). */
    fun migrate() {}

    val listCache: ListCache? get() = null
    val flutterFilesDir: File? get() = null
    val versionName: String
    val packageName: String
    val isLowRam: Boolean get() = false

    fun repositoryFor(p: Portal): IptvRepository =
        if (p.type == PortalType.demo) DemoRepository(p) else IptvRepository.forPortal(p)
}

/** Demo-Portal (Port von demo_repository.dart, nur Live-TV). */
class DemoRepository(p: Portal) : IptvRepository(p) {
    override fun login() = AccountInfo("Active", System.currentTimeMillis() + 214L * 86_400_000, 2, 1)
    override fun live() = LiveList(DemoData.categories, DemoData.channels)
    override fun loadEpg(
        channels: List<Channel>?,
        onProgress: ((Int, Int, Long, Long?) -> Unit)?,
    ): Map<String, List<EpgEntry>> = DemoData.epg()

    override fun catchupUrl(c: Channel, e: EpgEntry, nowMs: Long): String? = DemoData.catchupUrl(c)
}
