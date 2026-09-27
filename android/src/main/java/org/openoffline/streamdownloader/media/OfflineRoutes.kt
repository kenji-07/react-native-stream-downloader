package org.openoffline.streamdownloader.media

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.common.StreamKey
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import org.openoffline.streamdownloader.core.DownloadFailure
import org.openoffline.streamdownloader.core.Record
import org.openoffline.streamdownloader.core.State
import org.openoffline.streamdownloader.core.OfflineDrm

/** Immutable read index keeps player hooks free of SQLite and filesystem IO. */
class OfflineRoutes {
    data class Route(val id: String, val url: String, val mimeType: String?, val streamKeys: List<StreamKey>, val drm: OfflineDrm? = null)
    private val routes = AtomicReference<Map<String, Route>>(emptyMap())
    private val maintaining = mutableSetOf<String>()
    @Synchronized fun beginMaintenance(id: String) {
        if ((leases[id] ?: 0) > 0 || !maintaining.add(id)) throw DownloadFailure("E_ASSET_IN_USE", "Stop playback before renewing this asset license.", true)
    }
    @Synchronized fun endMaintenance(id: String) { maintaining.remove(id) }
    private val leases = mutableMapOf<String, Int>()
    @Volatile private var playbackEnabled = true
    fun setPlaybackEnabled(enabled: Boolean) { playbackEnabled = enabled }
    fun get(uri: Uri?): Route? = if (playbackEnabled) routes.get()[uri?.toString()] else null
    fun owns(uri: Uri?): Boolean = uri?.scheme == "rnv-offline" && uri.host == "asset"
    @Synchronized fun committed(record: Record) {
        if (record.stopIntent == "DELETE") { routes.set(routes.get().filterValues { it.id != record.id }); return }
        if (record.state == State.COMPLETED) record.asset?.let { asset ->
            val plan = asset.playback
            routes.set(routes.get() + (asset.path to Route(record.id, plan?.url ?: record.url, plan?.mimeType,
                plan?.streamKeys?.map { StreamKey(it[0], it[1], it[2]) } ?: emptyList(), plan?.drm)))
        }
    }
    @Synchronized fun <T> deleting(id: String, action: () -> T): T {
        if (id in maintaining || (leases[id] ?: 0) > 0) throw DownloadFailure("E_ASSET_IN_USE", "The asset is currently playing.", true)
        val snapshot = routes.get()
        routes.set(snapshot.filterValues { it.id != id })
        return try { action() } catch (error: Throwable) { routes.set(snapshot); throw error }
    }
    @Synchronized internal fun acquire(route: Route) {
        if (!playbackEnabled || route.id in maintaining || routes.get().values.none { it == route }) throw IOException("Offline asset is no longer available.")
        leases[route.id] = (leases[route.id] ?: 0) + 1
    }
    @Synchronized internal fun release(route: Route) {
        val remaining = (leases[route.id] ?: 1) - 1
        if (remaining == 0) leases.remove(route.id) else leases[route.id] = remaining
    }
    fun leased(route: Route, factory: DataSource.Factory): DataSource.Factory = DataSource.Factory {
        object : DataSource {
            private val delegate = factory.createDataSource()
            private var held = false
            override fun addTransferListener(listener: TransferListener) = delegate.addTransferListener(listener)
            override fun getUri(): Uri? = delegate.uri
            override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders
            override fun open(dataSpec: DataSpec): Long {
                acquire(route); held = true
                return try { delegate.open(dataSpec) } catch (error: Throwable) { close(); throw error }
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int = delegate.read(buffer, offset, length)
            override fun close() { try { delegate.close() } finally { if (held) { held = false; release(route) } } }
        }
    }
}
