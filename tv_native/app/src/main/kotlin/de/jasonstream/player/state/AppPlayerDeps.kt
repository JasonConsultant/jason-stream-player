package de.jasonstream.player.state

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.storage.Storage
import de.jasonstream.data.channels.VariantIndex
import de.jasonstream.player.logic.GroupIds
import de.jasonstream.playback.api.PlayerDeps
import kotlinx.coroutines.flow.StateFlow

/**
 * Brücke App → Player: EPG, Varianten, PIN und Verlauf kommen aus dem
 * [AppViewModel] (gleiche Daten wie Senderliste und Guide).
 */
class AppPlayerDeps(private val vm: AppViewModel, private val pinReason: () -> String) : PlayerDeps {
    override val storage: Storage get() = vm.storage ?: error("Speicher noch nicht geöffnet")

    override fun portal(portalId: String): Portal? =
        vm.portal.value?.takeIf { it.id == portalId } ?: vm.portals.value.firstOrNull { it.id == portalId }

    override suspend fun resolveLiveUrl(portalId: String, channel: Channel): String {
        val r = vm.repository()
        if (r != null && r.portal.id == portalId) return r.resolveStreamUrl(channel)
        return portal(portalId)?.let { HostFailover.rewrite(it, channel.streamUrl) } ?: channel.streamUrl
    }

    override suspend fun catchupUrl(portalId: String, channel: Channel, entry: EpgEntry): String? {
        val r = vm.repository() ?: return null
        if (r.portal.id != portalId) return null
        return runCatching { r.catchupUrl(channel, entry) }.getOrNull()
    }

    override fun epgOf(channel: Channel): List<EpgEntry> = vm.epg.value.of(channel)
    override val epgRevision: StateFlow<Long> get() = vm.epgRevision
    override fun wantEpg(channel: Channel) = vm.wantEpg(channel)
    override fun variantIndex(): VariantIndex = vm.live.value.variants
    override fun allChannels(portalId: String): List<Channel> = vm.live.value.channelsOf(GroupIds.ALL)
    override fun rawChannels(portalId: String): List<Channel> = vm.live.value.allById.values.toList()
    override suspend fun confirmPin(channel: Channel): Boolean = vm.confirmPin(pinReason())

    override fun onChannelStarted(portalId: String, channel: Channel) {
        super.onChannelStarted(portalId, channel) // Verlauf + letzter Sender (Gastmodus: nichts)
        vm.onChannelStarted()
    }

    override fun chooseVariant(portalId: String, channel: Channel) {
        super.chooseVariant(portalId, channel)
        vm.onChannelStarted()
    }
}
