package org.openoffline.streamdownloader.media

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import androidx.media3.common.MimeTypes
import androidx.media3.datasource.DataSource
import java.io.File
import java.nio.ByteBuffer
import org.openoffline.streamdownloader.core.DownloadFailure

/** Clear compressed samples are copied; protected samples are never decrypted. */
internal object MP4Remuxer {
    fun export(factory: DataSource.Factory, url: String, indices: List<Int>, output: File, checkStopped: () -> Unit): Long {
        if (indices.isEmpty()) throw DownloadFailure("E_INVALID_TRACKS", "At least one MP4 track must be retained.")
        val extractor = MediaExtractor()
        val source = ExtractorDataSource(factory, url)
        var muxer: MediaMuxer? = null
        var committed = false
        try {
            extractor.setDataSource(source)
            if (!extractor.psshInfo.isNullOrEmpty()) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Encrypted MP4 tracks cannot be remuxed by this clear-media exporter.")
            val selected = indices.distinct().associateWith { index ->
                if (index !in 0 until extractor.trackCount) throw DownloadFailure("E_INVALID_TRACKS", "The MP4 track layout changed during download.")
                extractor.getTrackFormat(index).also { format ->
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                    if (!MimeTypes.isVideo(mime) && !MimeTypes.isAudio(mime)) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "This native MP4 exporter supports audio and video sample tracks only.")
                }
            }
            if (!output.parentFile!!.isDirectory && !output.parentFile!!.mkdirs()) throw DownloadFailure("E_STORAGE", "The MP4 export directory could not be created.")
            muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val target = muxer
            selected.values.firstOrNull { MimeTypes.isVideo(it.getString(MediaFormat.KEY_MIME)) }?.let { format ->
                if (format.containsKey(MediaFormat.KEY_ROTATION)) target.setOrientationHint(format.getInteger(MediaFormat.KEY_ROTATION))
            }
            val mapping = selected.mapValues { (index, format) -> extractor.selectTrack(index); target.addTrack(format) }
            var capacity = selected.values.maxOf { if (it.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) it.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 1024 * 1024 }.coerceIn(1024 * 1024, 64 * 1024 * 1024)
            var buffer = ByteBuffer.allocateDirect(capacity)
            val info = MediaCodec.BufferInfo()
            var count = 0L
            target.start()
            while (true) {
                checkStopped()
                val index = extractor.sampleTrackIndex
                if (index < 0) break
                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED != 0) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Encrypted samples cannot be exported as clear media.")
                if (Build.VERSION.SDK_INT >= 28 && extractor.sampleSize > capacity) {
                    val required = extractor.sampleSize
                    if (required > 64 * 1024 * 1024) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "An MP4 sample exceeds the supported remux buffer size.")
                    capacity = required.toInt(); buffer = ByteBuffer.allocateDirect(capacity)
                }
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                if (size > capacity) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "An MP4 sample exceeds the supported remux buffer size.")
                val outputTrack = mapping[index] ?: throw DownloadFailure("E_INVALID_TRACKS", "An unselected MP4 sample was returned by the extractor.")
                info.set(0, size, extractor.sampleTime, if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                target.writeSampleData(outputTrack, buffer, info); count++
                if (!extractor.advance()) break
            }
            if (count == 0L) throw DownloadFailure("E_INVALID_STREAM", "The selected MP4 tracks contain no samples.")
            target.stop(); target.release(); muxer = null
            checkStopped()
            val duration = verify(output, selected.values.map { it.getString(MediaFormat.KEY_MIME) })
            committed = true; return duration
        } finally {
            try { muxer?.release() } finally { extractor.release(); source.close(); if (!committed) output.delete() }
        }
    }

    private fun verify(file: File, expected: List<String?>): Long {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            val formats = (0 until extractor.trackCount).map(extractor::getTrackFormat)
            val actual = formats.map { it.getString(MediaFormat.KEY_MIME) }
            if (actual.sortedBy { it } != expected.sortedBy { it } || file.length() <= 0) throw DownloadFailure("E_CORRUPT_ASSET", "The MP4 export does not contain exactly the selected tracks.")
            return formats.maxOfOrNull { if (it.containsKey(MediaFormat.KEY_DURATION)) it.getLong(MediaFormat.KEY_DURATION) / 1000 else 0 } ?: 0
        } finally { extractor.release() }
    }
}
