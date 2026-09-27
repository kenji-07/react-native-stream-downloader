package org.openoffline.streamdownloader.media

import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.PlaceholderDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.WrappingMediaSource
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import java.io.IOException
import com.brentvatne.common.api.Source
import com.brentvatne.exoplayer.RNVExoplayerPlugin

@UnstableApi
class OfflineVideoPlugin(private val routes: OfflineRoutes, private val engine: Media3Engine) : RNVExoplayerPlugin {
    override fun onInstanceCreated(id: String, player: ExoPlayer) = Unit
    override fun onInstanceRemoved(id: String, player: ExoPlayer) = Unit
    override fun shouldDisableCache(source: Source): Boolean = routes.owns(source.uri)
    override fun overrideMediaItemBuilder(source: Source, mediaItemBuilder: MediaItem.Builder): MediaItem.Builder? {
        val route = routes.get(source.uri) ?: return null
        return mediaItemBuilder.setUri(route.url).setMediaId(route.id).setMimeType(route.mimeType).setStreamKeys(route.streamKeys)
            .setDrmConfiguration(route.drm?.let(engine::drmConfiguration))
    }
    override fun overrideMediaDataSourceFactory(source: Source, mediaDataSourceFactory: DataSource.Factory): DataSource.Factory? {
        if (!routes.owns(source.uri)) return null
        val route = routes.get(source.uri) ?: return PlaceholderDataSource.FACTORY
        return routes.leased(route, engine.factory(route.id, false))
    }

    override fun overrideMediaSourceFactory(source: Source, mediaSourceFactory: MediaSource.Factory, mediaDataSourceFactory: DataSource.Factory): MediaSource.Factory? {
        if (!routes.owns(source.uri)) return null
        val route = routes.get(source.uri)
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
