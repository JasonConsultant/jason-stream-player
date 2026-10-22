package de.jasonstream.player

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.allowHardware
import de.jasonstream.data.net.Net
import okio.Path.Companion.toOkioPath

class JasonApp : Application(), SingletonImageLoader.Factory {
    val container: AppContainer by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        container.tuneForDevice()
    }

    /**
     * Bilder (Logos/Poster): Plattencache 128 MB, Arbeitsspeicher begrenzt –
     * auf 1–2-GB-Boxen nur ein kleiner Anteil, damit Player und EPG Luft haben.
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader {
        val percent = when {
            container.isLowRam -> 0.08
            container.memory.totalMem <= 2560L shl 20 -> 0.12
            else -> 0.2
        }
        return ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { Net.client })) }
            .memoryCache { MemoryCache.Builder().maxSizePercent(context, percent).build() }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("img").toOkioPath())
                    .maxSizeBytes(128L * 1024 * 1024)
                    .build()
            }
            // Hardware-Bitmaps sparen RAM, sind auf alten TV-Chips aber manchmal fehlerhaft.
            .allowHardware(!container.isLowRam)
            .build()
    }
}
