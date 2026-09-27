package org.openoffline.streamdownloader.media

import android.media.MediaDataSource
import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec

/** MediaExtractor reads through the same transport/cache policy as Media3. */
internal class ExtractorDataSource(private val factory: DataSource.Factory, private val url: String) : MediaDataSource() {
    override fun getSize(): Long {
        val source = factory.createDataSource()
        return try { source.open(DataSpec(Uri.parse(url))) } finally { source.close() }
    }
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size == 0) return 0
        val source = factory.createDataSource()
        return try {
            source.open(DataSpec.Builder().setUri(url).setPosition(position).build())
            source.read(buffer, offset, size)
        } finally { source.close() }
    }
    override fun close() = Unit
}
