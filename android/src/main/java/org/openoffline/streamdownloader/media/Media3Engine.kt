package org.openoffline.streamdownloader.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.ParserException
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.ProgressiveDownloader
import androidx.media3.exoplayer.offline.Downloader
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DefaultDownloadIndex
import androidx.media3.exoplayer.hls.offline.HlsDownloader
import androidx.media3.exoplayer.dash.offline.DashDownloader
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.openoffline.streamdownloader.core.LicenseUpdate
import org.openoffline.streamdownloader.core.Asset
import org.openoffline.streamdownloader.core.CacheRange
import org.openoffline.streamdownloader.core.PlaybackPlan
import org.openoffline.streamdownloader.core.DownloadFailure
import org.openoffline.streamdownloader.core.Engine
import org.openoffline.streamdownloader.core.Record
import org.openoffline.streamdownloader.core.Transfer
import org.openoffline.streamdownloader.core.TransferProgress
import org.openoffline.streamdownloader.core.TransferResult
import org.openoffline.streamdownloader.core.OfflineDrm
import org.openoffline.streamdownloader.drm.OfflineRights

/** Native transfer journal and cache owner. The queue remains the lifecycle authority. */
@UnstableApi
class Media3Engine(context: Context, private val routes: OfflineRoutes,
    private val http: DataSource.Factory = DefaultHttpDataSource.Factory().setUserAgent("OpenOffline/0.1")
        .setConnectTimeoutMs(15000).setReadTimeoutMs(15000).setAllowCrossProtocolRedirects(false),
) : Engine {
    private val network = NetworkPolicy(context)
    override fun setWifiOnly(value: Boolean) { network.wifiOnly = value; rights.retryPendingReleases() }
    internal fun observeNetwork(observer: (Boolean, Boolean) -> Unit) = network.observe(observer)
    private val workers = Executors.newCachedThreadPool()
    private val directory = File(context.noBackupFilesDir, "stream-downloader/media")
    private val exports = File(context.noBackupFilesDir, "stream-downloader/exports")
    private val database = StandaloneDatabaseProvider(context)
    private val cache = SimpleCache(directory, NoOpCacheEvictor(), database)
    private val journal = DefaultDownloadIndex(database, "OpenOffline")
    private val rights = OfflineRights(context, workers, network::allowed)

    internal fun drmConfiguration(drm: OfflineDrm) = rights.configuration(drm)
    internal fun drmProvider(drm: OfflineDrm?) = rights.playbackProvider(drm)

    fun factory(id: String, online: Boolean): CacheDataSource.Factory = CacheDataSource.Factory()
        .setCache(cache)
        .setCacheKeyFactory { spec -> "$id:${spec.key ?: spec.uri}" }
        .setUpstreamDataSourceFactory(if (online) network.wrap(http) else null)
        .also { if (!online) it.setCacheWriteDataSinkFactory(null) }

    fun tracks(url: String): CompletableFuture<Map<String, Any?>> = CompletableFuture.supplyAsync({
        try { MediaCatalog(network.wrap(http)).inspect(url).publicTracks() }
        catch (error: Exception) { throw failure(error) }
    }, workers)

    private fun downloader(item: MediaItem, id: String, online: Boolean): Downloader = when (item.localConfiguration?.mimeType) {
        MimeTypes.APPLICATION_M3U8 -> HlsDownloader(item, factory(id, online))
        MimeTypes.APPLICATION_MPD -> DashDownloader(item, factory(id, online))
        else -> ProgressiveDownloader(item, factory(id, online))
    }

    override fun start(record: Record, progress: (TransferProgress) -> Unit, finished: (TransferResult) -> Unit): Transfer {
        val stopped = AtomicBoolean(false)
        val current = AtomicReference<Downloader?>()
        val worker = AtomicReference<Thread?>()
        val acquiringLicense = AtomicBoolean(false)
        val cancellation = Any()
        workers.execute {
            synchronized(cancellation) { worker.set(Thread.currentThread()) }
            var received: Long? = null
            var total: Long? = null
            var request: DownloadRequest? = null
            val started = System.currentTimeMillis()
            fun checkStopped() { if (stopped.get()) throw InterruptedException() }
            val outcome = try {
                checkStopped()
                // Read through the same cache used for transfer. Resume keeps the
                // original manifest snapshot and cannot silently switch selections.
                val inspector = MediaCatalog(factory(record.id, true))
                val catalog = inspector.inspect(record.url)
                checkStopped()
                val selected = catalog.select(record.options)
                val remux = catalog.kind == "mp4" && selected.size != catalog.tracks.size
                val adaptive = inspector.adaptiveInfo(catalog, selected)
                val duration = adaptive.duration
                checkStopped()
                val mime = when (catalog.kind) { "hls" -> MimeTypes.APPLICATION_M3U8; "dash" -> MimeTypes.APPLICATION_MPD; else -> MimeTypes.VIDEO_MP4 }
                val keys = if (catalog.kind == "mp4") emptyList() else selected.mapNotNull { it.key }.distinct()
                val offlineDrm = if (adaptive.encrypted) {
                    if (catalog.kind == "mp4") throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Persistent Android DRM requires DASH or fragmented MP4 HLS; encrypted progressive MP4 export is unsupported.")
                    if (!record.options.containsKey("drm")) throw DownloadFailure("E_DRM_REQUIRED", "The selected media requires an offline license configuration.")
                    var formats = adaptive.drmFormats
                    if (formats.any { format -> format.drmInitData?.let { data ->
                            (0 until data.schemeDataCount).none { data[it].data?.isNotEmpty() == true }
                        } != false }) {
                        // Some DASH manifests signal the scheme but carry PSSH only
                        // in initialization segments. DownloadHelper demuxes metadata
                        // without requesting or decrypting a streaming license.
                        val probe = NativeTrackProbe.inspect(MediaItem.Builder().setUri(record.url).setMimeType(mime).setStreamKeys(keys).build(), factory(record.id, true))
                        formats = (formats + probe.filter { it.drmInitData != null }).distinct()
                    }
                    synchronized(cancellation) { checkStopped(); acquiringLicense.set(true) }
                    try { rights.prepare(record, catalog.fingerprint, catalog.kind, formats, stopped::get) }
                    finally { synchronized(cancellation) { acquiringLicense.set(false) } }
                } else null
                checkStopped()
                var playbackURL = record.url
                var playbackKeys = keys
                if (catalog.hls is HlsMultivariantPlaylist && keys.none { it.groupIndex == HlsMultivariantPlaylist.GROUP_INDEX_VARIANT }) {
                    val audio = selected.filter { it.type == "audio" && it.key != null }
                    if (audio.size != 1 || selected.any { it.type == "text" }) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "An audio-only HLS selection must retain one standalone audio rendition.")
                    playbackURL = audio.single().dto["uri"] as String
                    playbackKeys = emptyList()
                }
                request = DownloadRequest.Builder(record.id, Uri.parse(record.url)).setMimeType(mime).setStreamKeys(keys).build()
                journal.putDownload(Download(request, Download.STATE_DOWNLOADING, started, started, -1, 0, 0))
                val transfer = downloader(request.toMediaItem(), record.id, true)
                current.set(transfer); checkStopped()
                transfer.download { length, bytes, percent ->
                    checkStopped()
                    received = bytes; total = length.takeIf { it >= 0 }
                    if (record.options["checkStorageBeforeDownload"] == true && length > bytes && directory.usableSpace - 16L * 1024 * 1024 < length - bytes) {
                        throw DownloadFailure("E_INSUFFICIENT_STORAGE", "There is not enough free storage for this download.")
                    }
                    progress(TransferProgress(if (percent >= 0) percent.toDouble() / 100 else 0.0, received, total))
                }
                checkStopped()
                // Traverse exactly the selected manifest/segments with no upstream.
                // A missing byte range is an error, never an online fallback.
                val verification = downloader(request.toMediaItem(), record.id, false)
                current.set(verification); checkStopped()
                verification.download { _, _, _ -> checkStopped() }
                var verifiedDuration = if (catalog.kind == "mp4") duration(record) else duration
                if (catalog.kind == "mp4" && !completeCache(record)) throw DownloadFailure("E_CORRUPT_ASSET", "The downloaded MP4 cache is incomplete.")
                if (remux) {
                    val output = File(exports, "${record.id}/selected.mp4")
                    try {
                        val completeCatalog = MediaCatalog(factory(record.id, false)).inspect(record.url)
                        if (completeCatalog.fingerprint != catalog.fingerprint) throw DownloadFailure("E_INVALID_TRACKS", "The MP4 track layout changed during download.")
                        verifiedDuration = MP4Remuxer.export(factory(record.id, false), record.url, selected.map { it.key!!.streamIndex }, output, ::checkStopped)
                        val outputURL = Uri.fromFile(output).toString()
                        val outputKey = "${record.id}:$outputURL"
                        cache.removeResource(outputKey)
                        val localCache = factory(record.id, false).setUpstreamDataSourceFactory(FileDataSource.Factory())
                            .setCacheWriteDataSinkFactory(androidx.media3.datasource.cache.CacheDataSink.Factory().setCache(cache))
                        val exportTransfer = ProgressiveDownloader(MediaItem.fromUri(outputURL), localCache)
                        current.set(exportTransfer); checkStopped()
                        exportTransfer.download { _, _, _ -> checkStopped() }
                        if (!cache.isCached(outputKey, 0, output.length())) throw DownloadFailure("E_CORRUPT_ASSET", "The MP4 export cache is incomplete.")
                        // Only the selected output remains in the published asset.
                        cache.keys.filter { it.startsWith("${record.id}:") && it != outputKey }.forEach(cache::removeResource)
                        playbackURL = outputURL
                    } finally { output.delete() }
                }
                val ranges = cache.keys.filter { it.startsWith("${record.id}:") }.flatMap { key ->
                    cache.getCachedSpans(key).map { CacheRange(key, it.position, it.length) }
                }
                if (ranges.isEmpty()) throw DownloadFailure("E_CORRUPT_ASSET", "The downloaded media cache is incomplete.")
                checkStopped()
                if (offlineDrm != null) {
                    synchronized(cancellation) { checkStopped(); acquiringLicense.set(true) }
                    try { rights.verifyForCommit(record.id, offlineDrm) }
                    finally { synchronized(cancellation) { acquiringLicense.set(false) } }
                    checkStopped()
                }
                val plan = PlaybackPlan(playbackURL, mime, playbackKeys.map { listOf(it.periodIndex, it.groupIndex, it.streamIndex) }, ranges, offlineDrm)
                val suffix = when (catalog.kind) {
                    "hls" -> "manifest.m3u8"
                    "dash" -> "manifest.mpd"
                    else -> AssetFileName.mp4((record.options["metadata"] as? Map<*, *>)?.get("title") as? String)
                }
                val offlineURI = Uri.Builder().scheme("rnv-offline").authority("asset").appendPath(record.id).appendPath(suffix).build().toString()
                journal.putDownload(Download(request, Download.STATE_COMPLETED, started, System.currentTimeMillis(), total ?: -1, 0, 0))
                TransferResult.Complete(Asset(offlineURI, verifiedDuration, System.currentTimeMillis(), plan), received, total)
            } catch (error: Throwable) {
                if (stopped.get()) TransferResult.Stopped
                else TransferResult.Failed(failure(error))
            } finally {
                synchronized(cancellation) {
                    worker.set(null); current.set(null)
                    // Do not let a late stop interrupt the next job on this pooled thread.
                    Thread.interrupted()
                }
            }
            val persisted = try {
                if (outcome == TransferResult.Stopped && request != null) journal.putDownload(Download(request, Download.STATE_STOPPED, started, System.currentTimeMillis(), total ?: -1, 1, 0))
                outcome
            } catch (_: Exception) { TransferResult.Failed(DownloadFailure("E_STORAGE", "Could not save the transfer checkpoint.")) }
            finished(persisted)
        }
        return Transfer { synchronized(cancellation) {
            stopped.set(true); current.get()?.cancel()
            // OfflineLicenseHelper owns a separate handler and cannot safely be
            // abandoned by thread interruption. Its bounded transport observes
            // cancellation; persist any late acquired key-set before acknowledging.
            if (!acquiringLicense.get()) worker.get()?.interrupt()
        } }
    }

    override fun resolvedRecord(record: Record): Record {
        val asset = record.asset ?: return record
        val plan = asset.playback ?: return record
        if (plan.drm == null) return record
        val latest = rights.current(record.id) ?: return record
        return record.copy(asset = asset.copy(playback = plan.copy(drm = latest)))
    }
    override fun license(record: Record, renew: Boolean, config: Map<String, Any?>?): CompletableFuture<LicenseUpdate> = CompletableFuture.supplyAsync({
        val asset = record.asset
        val plan = asset?.playback
        if (plan?.drm == null) {
            if (renew) throw DownloadFailure("E_DRM_REQUIRED", "This asset has no persistent DRM license.")
            LicenseUpdate(null)
        } else if (!renew) LicenseUpdate(rights.status(record.id))
        else {
            routes.beginMaintenance(record.id)
            try {
                val renewed = rights.renew(record.id, config)
                LicenseUpdate(runCatching { rights.status(record.id) }.getOrElse { mapOf("id" to record.id, "scheme" to if (renewed.scheme == androidx.media3.common.C.WIDEVINE_UUID.toString()) "widevine" else "playready", "state" to "unknown", "checkedAt" to System.currentTimeMillis()) }, asset.copy(playback = plan.copy(drm = renewed))) { routes.endMaintenance(record.id) }
            } catch (error: Throwable) { routes.endMaintenance(record.id); throw error }
        }
    }, workers)

    override fun delete(record: Record) = delete(record) {}
    override fun delete(record: Record, beforeRemoving: () -> Unit) {
        routes.deleting(record.id) {
            beforeRemoving()
            rights.remove(record.id)
            journal.getDownload(record.id)?.let { journal.putDownload(Download(it.request, Download.STATE_REMOVING, it.startTimeMs, System.currentTimeMillis(), it.contentLength, 0, 0)) }
            cache.keys.filter { it.startsWith("${record.id}:") }.forEach { cache.removeResource(it) }
            val output = File(exports, record.id)
            if (output.exists() && !output.deleteRecursively()) throw DownloadFailure("E_STORAGE", "Temporary MP4 export files could not be removed.")
            journal.removeDownload(record.id)
        }
    }

    private fun completeCache(record: Record): Boolean {
        val key = "${record.id}:${record.url}"
        val length = ContentMetadata.getContentLength(cache.getContentMetadata(key))
        return length > 0 && cache.isCached(key, 0, length)
    }
    internal fun close() { workers.shutdownNow(); cache.release(); database.close() }
    override fun valid(record: Record): Boolean {
        val asset = record.asset ?: return false
        val plan = asset.playback ?: return completeCache(record)
        if (plan.drm?.let { !rights.valid(record.id, it) } == true) return false
        return plan.ranges.isNotEmpty() && plan.ranges.all { it.key.startsWith("${record.id}:") && it.position >= 0 && it.length > 0 && cache.isCached(it.key, it.position, it.length) }
    }

    private fun failure(error: Throwable): DownloadFailure {
        val causes = generateSequence(error) { it.cause }.take(16).toList()
        causes.filterIsInstance<DownloadFailure>().firstOrNull()?.let { return it }
        if (causes.any { it is android.database.sqlite.SQLiteFullException ||
                (it is android.system.ErrnoException && it.errno == android.system.OsConstants.ENOSPC) ||
                (it is IOException && (it.message?.contains("ENOSPC") == true || it.message?.contains("No space left on device", true) == true)) }) {
            return DownloadFailure("E_INSUFFICIENT_STORAGE", "There is not enough free storage to finish this download.")
        }
        val httpFailure = causes.filterIsInstance<androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException>().firstOrNull()
        if (httpFailure != null) return DownloadFailure("E_NETWORK", "The media server rejected the request.", httpFailure.responseCode in setOf(408, 429) || httpFailure.responseCode in 500..599)
        return when {
            causes.any { it is ParserException } -> DownloadFailure("E_MANIFEST", "The media manifest is invalid or unsupported.")
            causes.any { it is androidx.media3.datasource.cache.Cache.CacheException || it is android.database.sqlite.SQLiteException ||
                (it is android.system.ErrnoException && it.errno in listOf(android.system.OsConstants.EIO, android.system.OsConstants.EROFS)) } ->
                DownloadFailure("E_STORAGE", "The media files or download journal could not be read or written.")
            error is IOException -> DownloadFailure("E_NETWORK", "Media transfer or verification failed.", true)
            else -> DownloadFailure("E_DOWNLOAD", "Media preparation, transfer or verification failed.")
        }
    }

    private fun duration(record: Record): Long {
        val extractor = MediaExtractor()
        val source = ExtractorDataSource(factory(record.id, false), record.url)
        try {
            extractor.setDataSource(source)
            if (extractor.trackCount == 0) throw DownloadFailure("E_INVALID_STREAM", "The MP4 does not contain playable tracks.")
            if (!extractor.psshInfo.isNullOrEmpty()) throw DownloadFailure("E_DRM_REQUIRED", "Encrypted media requires persistent license preparation.")
            var durationUs = 0L
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                if (format.containsKey(MediaFormat.KEY_DURATION)) durationUs = maxOf(durationUs, format.getLong(MediaFormat.KEY_DURATION))
            }
            return durationUs / 1000
        } finally { extractor.release(); source.close() }
    }

}
