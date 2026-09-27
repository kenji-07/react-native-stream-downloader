package org.openoffline.streamdownloader.media

import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/** Application headers for every upstream media request: manifests, segments, HLS keys and MP4 bytes. */
@UnstableApi
internal object RequestHeaders {
    @Suppress("UNCHECKED_CAST")
    fun of(options: Map<String, Any?>): Map<String, String> = options["headers"] as? Map<String, String> ?: emptyMap()

    fun wrap(factory: DataSource.Factory, headers: Map<String, String>): DataSource.Factory = if (headers.isEmpty()) factory else DataSource.Factory {
        val source = factory.createDataSource()
        object : DataSource {
            override fun addTransferListener(listener: TransferListener) = source.addTransferListener(listener)
            override fun open(dataSpec: DataSpec): Long = source.open(dataSpec.withAdditionalHeaders(headers))
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int = source.read(buffer, offset, length)
            override fun getUri() = source.uri
            override fun getResponseHeaders() = source.responseHeaders
            override fun close() = source.close()
        }
    }
}
