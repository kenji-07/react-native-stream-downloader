package org.openoffline.streamdownloader.core

class DownloadFailure(val code: String, message: String, val retryable: Boolean = false) : Exception(message)

enum class State(val wire: String) {
    PENDING("pending"), DOWNLOADING("downloading"), PAUSED("paused"), COMPLETED("completed"), FAILED("failed"), REMOVED("removed");
    val unfinished: Boolean get() = this == PENDING || this == DOWNLOADING || this == PAUSED
}

data class CacheRange(val key: String, val position: Long, val length: Long)
/** An opaque platform rights reference, never decrypted content keys. */
data class OfflineDrm(val scheme: String, val keySetId: String)
data class PlaybackPlan(val url: String, val mimeType: String, val streamKeys: List<List<Int>>, val ranges: List<CacheRange>, val drm: OfflineDrm? = null)
data class Asset(val path: String, val duration: Long, val date: Long, val playback: PlaybackPlan? = null)

data class Record(
    val id: String,
    val url: String,
    var options: Map<String, Any?>,
    val fingerprint: String,
    val order: Long,
    val generation: Long = 1,
    var state: State = State.PENDING,
    var progress: Double = 0.0,
    var received: Long? = null,
    var total: Long? = null,
    var error: String? = null,
    var asset: Asset? = null,
    var expiresAt: Long = 0,
    var disableHeld: Boolean = false,
    var stopIntent: String? = null,
    var retryCount: Int = 0,
    var nextRetryAt: Long? = null,
) {
    fun status(): Map<String, Any?> = buildMap {
        put("id", id); put("url", url); put("progress", progress); put("status", state.wire)
        received?.let { put("receivedBytes", it) }; total?.let { put("totalBytes", it) }
        if (retryCount > 0) put("retryCount", retryCount)
        nextRetryAt?.let { put("nextRetryAt", it) }
        error?.let { put("error", it) }; options["metadata"]?.let { put("metadata", it) }
    }

    fun downloadedAsset(): Map<String, Any?>? = asset?.let { media -> buildMap {
        put("id", id); put("url", url); put("pathToFile", media.path)
        put("title", (options["metadata"] as? Map<*, *>)?.get("title") as? String ?: "")
        put("duration", media.duration); put("downloadDate", media.date)
        if (expiresAt != 0L) put("expiresAt", expiresAt)
        options["metadata"]?.let { put("metadata", it) }
    } }
}

interface Store {
    fun load(): List<Record>
    fun put(record: Record)
    fun remove(id: String)
    fun enabled(): Boolean
    fun setEnabled(enabled: Boolean)
    fun configuration(): Map<String, Any?> = emptyMap()
    fun setConfiguration(value: Map<String, Any?>) {}
}

data class TransferProgress(val fraction: Double, val received: Long?, val total: Long?)
sealed class TransferResult {
    data class Complete(val asset: Asset, val received: Long?, val total: Long?) : TransferResult()
    data class Failed(val error: DownloadFailure) : TransferResult()
    data object Stopped : TransferResult()
}
fun interface Transfer { fun stop() }

interface Engine {
    fun start(record: Record, progress: (TransferProgress) -> Unit, finished: (TransferResult) -> Unit): Transfer
    fun delete(record: Record)
    /** Engines with player leases acquire the deletion guard before this commit. */
    fun delete(record: Record, beforeRemoving: () -> Unit) { beforeRemoving(); delete(record) }
    fun valid(record: Record): Boolean
    fun setWifiOnly(value: Boolean) {}
    fun prepareRetry(record: Record) {}
    fun resolvedRecord(record: Record): Record = record
    fun license(record: Record, renew: Boolean, config: Map<String, Any?>?): java.util.concurrent.CompletableFuture<LicenseUpdate> =
        java.util.concurrent.CompletableFuture<LicenseUpdate>().also { it.completeExceptionally(DownloadFailure("E_UNSUPPORTED_CAPABILITY", "DRM license management is unavailable.")) }
}

data class DownloadPolicy(val wifiOnly: Boolean = false, val maxRetries: Int = 0, val initialDelayMS: Long = 1000, val maxDelayMS: Long = 30000) {
    fun retryDelay(count: Int): Long = (initialDelayMS * (1L shl (count - 1).coerceIn(0, 10))).coerceAtMost(maxDelayMS)
    fun wire(): Map<String, Any?> = mapOf("wifiOnly" to wifiOnly, "retry" to mapOf("maxRetries" to maxRetries, "initialDelayMS" to initialDelayMS, "maxDelayMS" to maxDelayMS))
    fun updated(config: Map<String, Any?>): DownloadPolicy {
        val retry = config["retry"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val next = copy(wifiOnly = config["wifiOnly"] as? Boolean ?: wifiOnly,
            maxRetries = (retry["maxRetries"] as? Number)?.toInt() ?: maxRetries,
            initialDelayMS = (retry["initialDelayMS"] as? Number)?.toLong() ?: initialDelayMS,
            maxDelayMS = (retry["maxDelayMS"] as? Number)?.toLong() ?: maxDelayMS)
        if (next.maxRetries !in 0..10 || next.initialDelayMS !in 1..86400000 || next.maxDelayMS !in next.initialDelayMS..86400000) throw DownloadFailure("E_INVALID_ARGUMENT", "Invalid retry policy.")
        return next
    }
}

/** Small rolling window; only in-memory samples, never stale persisted rates. */
class TransferRate {
    private val samples = java.util.ArrayDeque<Pair<Long, Long>>()
    fun record(bytes: Long?, time: Long) {
        if (bytes == null) { samples.clear(); return }
        if (samples.peekLast()?.let { bytes < it.second } == true) samples.clear()
        samples.add(time to bytes)
        while (samples.size > 2 && time - samples.first.first > 5000) samples.removeFirst()
        while (samples.size > 64) samples.removeFirst()
    }
    fun rate(time: Long): Double? {
        val first = samples.peekFirst() ?: return null; val last = samples.peekLast() ?: return null
        if (time - last.first > 3000) return 0.0
        if (last.first <= first.first) return null
        return ((last.second - first.second).toDouble() * 1000 / (last.first - first.first)).coerceAtLeast(0.0)
    }
}

data class LicenseUpdate(val status: Map<String, Any?>?, val asset: Asset? = null, val release: () -> Unit = {})
