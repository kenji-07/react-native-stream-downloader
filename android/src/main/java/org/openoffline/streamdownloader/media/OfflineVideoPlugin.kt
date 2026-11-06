package org.openoffline.streamdownloader.media

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.PlaceholderDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.WrappingMediaSource
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import java.io.IOException
import com.twg.video.core.plugins.NativeVideoPlayerSource
import com.twg.video.core.plugins.ReactNativeVideoPlugin

@UnstableApi
class OfflineVideoPlugin(private val routes: OfflineRoutes, private val engine: Media3Engine) : ReactNativeVideoPlugin("StreamDownloaderOffline") {
    private fun uri(source: NativeVideoPlayerSource): Uri? = try { Uri.parse(source.uri) } catch (_: Throwable) { null }

    override fun shouldDisableCache(source: NativeVideoPlayerSource): Boolean = routes.owns(uri(source))
    override fun getMediaItemBuilder(source: NativeVideoPlayerSource, mediaItemBuilder: MediaItem.Builder): MediaItem.Builder? {
        val route = routes.get(uri(source)) ?: return null
        return mediaItemBuilder.setUri(route.url).setMediaId(route.id).setMimeType(route.mimeType).setStreamKeys(route.streamKeys)
            .setDrmConfiguration(route.drm?.let(engine::drmConfiguration))
    }
    override fun getMediaDataSourceFactory(source: NativeVideoPlayerSource, mediaDataSourceFactory: DataSource.Factory): DataSource.Factory? {
        if (!routes.owns(uri(source))) return null
        val route = routes.get(uri(source)) ?: return PlaceholderDataSource.FACTORY
        return routes.leased(route, engine.factory(route.id, false))
    }

    override fun getMediaSourceFactory(source: NativeVideoPlayerSource, mediaSourceFactory: MediaSource.Factory, mediaDataSourceFactory: DataSource.Factory): MediaSource.Factory? {
        if (!routes.owns(uri(source))) return null
        val route = routes.get(uri(source))
        // RNV creates a separate DASH manifest source. Replace the whole factory
        // so manifest, initialization, index and segment reads share cache-only IO.
        val delegate = DefaultMediaSourceFactory(if (route == null) PlaceholderDataSource.FACTORY else engine.factory(route.id, false))
        val offlineDrmProvider = engine.drmProvider(route?.drm)
        delegate.setDrmSessionManagerProvider(offlineDrmProvider)
        return object : MediaSource.Factory {
            // react-native-video calls this AFTER the plugin hook. Retain our
            // asset-scoped offline manager instead of its online-capable default.
            override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider): MediaSource.Factory { return this }
            override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy): MediaSource.Factory { delegate.setLoadErrorHandlingPolicy(policy); return this }
            override fun getSupportedTypes(): IntArray = delegate.supportedTypes
            override fun createMediaSource(mediaItem: MediaItem): MediaSource {
                val item = if (route == null) mediaItem.buildUpon().setDrmConfiguration(null).build()
                    else mediaItem.buildUpon().setUri(route.url).setMediaId(route.id).setMimeType(route.mimeType)
                        .setStreamKeys(route.streamKeys).setDrmConfiguration(route.drm?.let(engine::drmConfiguration)).build()
                val child = delegate.createMediaSource(item)
                if (route == null) return child
                return object : WrappingMediaSource(child) {
                    private var held = false
                    private var unavailable: IOException? = null
                    override fun prepareSourceInternal() {
                        try { routes.acquire(route); held = true }
                        catch (error: IOException) { unavailable = error; return }
                        super.prepareSourceInternal()
                    }
                    override fun maybeThrowSourceInfoRefreshError() {
                        unavailable?.let { throw it }
                        super.maybeThrowSourceInfoRefreshError()
                    }
                    override fun releaseSourceInternal() {
                        try { super.releaseSourceInternal() }
                        finally { if (held) { held = false; routes.release(route) }; unavailable = null }
                    }
                }
            }
        }
    }
}
