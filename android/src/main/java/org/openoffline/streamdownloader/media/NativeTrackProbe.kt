package org.openoffline.streamdownloader.media

import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.offline.DownloadHelper
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.openoffline.streamdownloader.core.DownloadFailure

/** Reads actual demuxed track groups; a media playlist alone does not reveal them. */
@UnstableApi
internal object NativeTrackProbe {
    fun hls(url: String, factory: DataSource.Factory): List<Format> = inspect(
        MediaItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build(), factory)

    fun inspect(item: MediaItem, factory: DataSource.Factory): List<Format> {
        val thread = HandlerThread("OfflineTrackProbe").apply { start() }
        val handler = Handler(thread.looper)
        val result = CompletableFuture<List<Format>>()
        var helper: DownloadHelper? = null // confined to handler
        handler.post {
            try {
                helper = DownloadHelper.forMediaItem(
                    item,
                    TrackSelectionParameters.DEFAULT_WITHOUT_CONTEXT, null, factory,
                ).also { probe ->
                    probe.prepare(object : DownloadHelper.Callback {
                        override fun onPrepared(helper: DownloadHelper) {
                            try {
                                val formats = buildList {
                                    for (period in 0 until helper.periodCount) {
                                        val groups = helper.getTrackGroups(period)
                                        for (group in 0 until groups.length) {
                                            val tracks = groups[group]
                                            for (track in 0 until tracks.length) add(tracks.getFormat(track))
                                        }
                                    }
                                }.distinct()
                                result.complete(formats)
                            } catch (error: Exception) { result.completeExceptionally(error) }
                        }
                        override fun onPrepareError(helper: DownloadHelper, error: IOException) { result.completeExceptionally(error) }
                    })
                }
            } catch (error: Exception) { result.completeExceptionally(error) }
        }
        return try { result.get(60, TimeUnit.SECONDS) }
        catch (error: ExecutionException) { throw error.cause ?: error }
        catch (_: TimeoutException) { throw DownloadFailure("E_NETWORK", "Media track inspection timed out.", true) }
        finally { handler.post { helper?.release(); thread.quitSafely() } }
    }
}
