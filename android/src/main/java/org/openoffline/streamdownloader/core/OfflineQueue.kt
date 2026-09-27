package org.openoffline.streamdownloader.core

import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** All mutable state and persistence are confined to actor. IO runs in Engine. */
class OfflineQueue(
    private val store: Store,
    private val engine: Engine,
    private val event: (String, Any) -> Unit,
    private val actor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
    private val now: () -> Long = System::currentTimeMillis,
    private val requestWorker: () -> Boolean = { true },
    private val workChanged: (Boolean) -> Unit = {},
    private val playbackEnabled: (Boolean) -> Unit = {},
    private val monotonic: () -> Long = { System.nanoTime() / 1000000 },
) {
    private enum class Stop { PAUSE, LIMIT, NETWORK, DISABLE, CANCEL }
    private data class Running(val token: Long, val transfer: Transfer, var stop: Stop? = null, val rate: TransferRate = TransferRate())
    private data class Barrier(val future: CompletableFuture<Any?>, val ready: () -> Boolean, val value: Any?)
    private val records = linkedMapOf<String, Record>()
    private val active = linkedMapOf<String, Running>()
    private val dirtyProgress = mutableSetOf<String>()
    private val barriers = mutableListOf<Barrier>()
    private var loaded = false
    private var configurationLoaded = false
    private var policy = DownloadPolicy()
    private var connected = true
    private var wifi = false
    private val networkAllowed: Boolean get() = connected && (!policy.wifiOnly || wifi)
    private var retryTimer: ScheduledFuture<*>? = null
    private val licensing = mutableSetOf<String>()
    private var enabled = false
    private var maxParallel = 5
    private var frequency = 1000L
    private var order = 0L
    private var token = 0L
    private var progressEnabled = false
    private var timer: ScheduledFuture<*>? = null
    private var fault: DownloadFailure? = null

    fun execute(method: String, params: Map<String, Any?>): CompletableFuture<Any?> {
        val result = CompletableFuture<Any?>()
        actor.execute {
            try {
                fault?.let { throw it }; loadConfiguration()
                if (method == "registerPlugin") {
                    recover()
                    store.setEnabled(true)
                    enabled = true; playbackEnabled(true)
                    records.values.filter { it.disableHeld }.forEach { it.disableHeld = false; it.state = State.PENDING; save(it) }
                    pump(); result.complete(true)
                } else if (method == "disablePlugin") {
                    recover()
                    store.setEnabled(false); enabled = false; playbackEnabled(false)
                    records.values.filter { it.state == State.PENDING }.forEach { it.disableHeld = true; it.state = State.PAUSED; save(it) }
                    active.keys.toList().forEach { stop(it, Stop.DISABLE) }
                    barrier(result, { active.isEmpty() && licensing.isEmpty() }, true)
                } else {
                    if (!enabled && method != "getConfig" && method != "setConfig") throw DownloadFailure("E_NOT_REGISTERED", "Call registerPlugin before using the downloader.")
                    when (method) {
                        "getConfig" -> result.complete(configuration())
                        "setConfig" -> {
                            @Suppress("UNCHECKED_CAST") val config = params["config"] as Map<String, Any?>
                            val nextPolicy = policy.updated(config)
                            val policyChanged = nextPolicy.wifiOnly != policy.wifiOnly
                            val policyTransfers = if (policyChanged) active.mapValues { it.value.token } else emptyMap()
                            val limit = (config["maxParallelDownloads"] as? Number)?.toInt() ?: maxParallel
                            val nextFrequency = (config["updateFrequencyMS"] as? Number)?.toLong() ?: frequency
                            store.setConfiguration(nextPolicy.wire() + mapOf("maxParallelDownloads" to limit, "updateFrequencyMS" to nextFrequency))
                            frequency = nextFrequency; maxParallel = limit; policy = nextPolicy; engine.setWifiOnly(policy.wifiOnly)
                            if (policyChanged || !networkAllowed) active.keys.toList().forEach { stop(it, Stop.NETWORK) }
                            active.entries.toList().drop(maxParallel).forEach { stop(it.key, Stop.LIMIT) }
                            reschedule(); pump()
                            barrier(result, { active.size <= limit && active.values.none { it.stop == Stop.NETWORK } &&
                                policyTransfers.all { (id, token) -> active[id]?.token != token } }, null)
                        }
                        "downloadStream" -> {
                            @Suppress("UNCHECKED_CAST") val options = params["options"] as Map<String, Any?>
                            val fingerprint = params["fingerprint"] as String
                            val existing = records.values.firstOrNull { it.state.unfinished && it.fingerprint == fingerprint }
                            val record = existing ?: Record(UUID.randomUUID().toString(), params["url"] as String, options, fingerprint, ++order,
                                expiresAt = (options["expiresAt"] as? Number)?.toLong() ?: 0).also { save(it); records[it.id] = it }
                            persistProgress(record.id)
                            // Admission is committed before engine preparation or completion.
                            result.complete(status(record)); pump()
                        }
                        "getDownloadsStatus" -> { persistProgress(); result.complete(records.values.map(::status)) }
                        "getDownloadStatus" -> {
                            persistProgress(params["id"] as String)
                            result.complete(records[params["id"]]?.let(::status))
                        }
                        "pauseDownload" -> {
                            val record = requireRecord(params)
                            if (!record.state.unfinished) throw DownloadFailure("E_INVALID_STATE", "Only unfinished downloads can be paused.")
                            if (active.containsKey(record.id)) stop(record.id, Stop.PAUSE)
                            else { record.state = State.PAUSED; record.disableHeld = false; save(record) }
                            barrier(result, { !active.containsKey(record.id) }, null)
                        }
                        "resumeDownload" -> {
                            val record = requireRecord(params)
                            if (!record.state.unfinished) throw DownloadFailure("E_INVALID_STATE", "Only unfinished downloads can be resumed.")
                            if (active[record.id]?.stop != null) throw DownloadFailure("E_BUSY", "Wait for the pending pause or cancellation to finish.", true)
                            if (record.state == State.PAUSED) { record.state = State.PENDING; record.disableHeld = false; save(record) }
                            pump(); result.complete(null)
                        }
                        "cancelDownload", "cancelAllDownloads" -> {
                            val ids = if (method == "cancelDownload") listOf(params["id"] as String) else records.values.filter { it.state.unfinished }.map { it.id }
                            ids.forEach { cancel(it) }
                            barrier(result, { ids.none { active.containsKey(it) } }, null)
                        }
                        "deleteQueuedItem", "deleteAllQueuedItems" -> {
                            val items = if (method == "deleteQueuedItem") listOfNotNull(records[params["id"]])
                                else records.values.filter { it.state == State.PENDING || it.state == State.PAUSED || it.state == State.FAILED }
                            if (items.any { active.containsKey(it.id) || it.state == State.COMPLETED }) throw DownloadFailure("E_INVALID_STATE", "The queued item is active or completed.")
                            items.forEach { remove(it, it.state.unfinished) }; result.complete(null)
                        }
                        "getDownloadedAssets" -> result.complete(records.values.filter { it.state == State.COMPLETED }.sortedWith(compareBy({ it.asset?.date }, { it.id })).map { checkedAsset(it) })
                        "getDownloadedAsset" -> result.complete(records[params["id"]]?.takeIf { it.state == State.COMPLETED }?.let { checkedAsset(it) })
                        "deleteDownloadedAsset", "deleteAllDownloadedAssets" -> {
                            val items = if (method == "deleteDownloadedAsset") listOfNotNull(records[params["id"]]?.takeIf { it.state == State.COMPLETED })
                                else records.values.filter { it.state == State.COMPLETED }
                            items.forEach { remove(it, false) }; result.complete(null)
                        }
                        "getDRMLicenseStatus", "renewDRMLicense" -> {
                            val record = records[params["id"]]?.takeIf { it.state == State.COMPLETED }
                            if (record == null) {
                                if (method == "getDRMLicenseStatus") result.complete(null)
                                else throw DownloadFailure("E_ASSET_NOT_FOUND", "A completed asset was not found.")
                            } else license(record, method == "renewDRMLicense", params, result)
                        }
                        "expireDownloadedAssetAt" -> {
                            val record = requireRecord(params)
                            if (record.state != State.COMPLETED) throw DownloadFailure("E_ASSET_NOT_FOUND", "A completed asset was not found.")
                            record.expiresAt = (params["timestamp"] as Number).toLong(); save(record); result.complete(null)
                        }
                        else -> throw DownloadFailure("E_BRIDGE", "Unknown native operation.")
                    }
                }
                checkBarriers(); rescheduleIfNeeded()
            } catch (error: Throwable) { result.completeExceptionally(error) }
        }
        return result
    }

    fun setNetworkState(connected: Boolean, wifi: Boolean) { actor.execute {
        try {
            this.connected = connected; this.wifi = wifi
            if (!networkAllowed) active.keys.toList().forEach { stop(it, Stop.NETWORK) }
            pump(); rescheduleIfNeeded()
        } catch (error: Throwable) { halt(error) }
    } }

    fun setProgressEnabled(value: Boolean) { actor.execute { progressEnabled = value; reschedule() } }

    /** Called by the native service; never changes a durable explicit disable. */
    fun restoreBackground() { actor.execute {
        try {
            if (!loaded) { loadConfiguration(); recover(); enabled = store.enabled(); playbackEnabled(enabled) }
            pump(); rescheduleIfNeeded()
        } catch (error: Throwable) { halt(error) }
    } }

    fun workerReady() { actor.execute {
        try { pump(); rescheduleIfNeeded() } catch (error: Throwable) { halt(error) }
    } }

    fun workerUnavailable(message: String) { actor.execute {
        try {
            active.keys.toList().forEach { stop(it, Stop.LIMIT) }
            event("onError", message)
            rescheduleIfNeeded()
        } catch (error: Throwable) { halt(error) }
    } }

    fun close(): CompletableFuture<Any?> = execute("disablePlugin", emptyMap()).whenComplete { _, _ -> actor.shutdown() }

    private fun recover() {
        if (loaded) return
        store.load().forEach { stored ->
            val record = engine.resolvedRecord(stored)
            order = maxOf(order, record.order)
            if (record.state == State.REMOVED) return@forEach
            if (record.stopIntent == Stop.CANCEL.name || record.stopIntent == "DELETE") { engine.delete(record); store.remove(record.id); return@forEach }
            if (record.state == State.FAILED) engine.delete(record)
            if (record.stopIntent == Stop.PAUSE.name || record.stopIntent == Stop.DISABLE.name) record.state = State.PAUSED
            if (record.state == State.DOWNLOADING) { record.state = State.PENDING; save(record) }
            record.stopIntent = null; save(record)
            records[record.id] = record
            if (record.expiresAt > 0 && record.expiresAt <= now() && record.state == State.COMPLETED) remove(record, false)
        }
        loaded = true
    }

    private fun requireRecord(params: Map<String, Any?>): Record = records[params["id"]]
        ?: throw DownloadFailure("E_ASSET_NOT_FOUND", "The requested download was not found.")

    private fun checkedAsset(record: Record): Map<String, Any?> {
        if (!engine.valid(record)) throw DownloadFailure("E_CORRUPT_ASSET", "Downloaded media is missing or corrupted.")
        return record.downloadedAsset() ?: throw DownloadFailure("E_CORRUPT_ASSET", "Asset metadata is incomplete.")
    }

    private fun save(record: Record) {
        try { store.put(record); dirtyProgress.remove(record.id) } catch (error: Throwable) { halt(error); throw fault!! }
    }

    private fun pump() {
        if (!enabled || fault != null || !networkAllowed) return
        val candidates = records.values.filter { it.state == State.PENDING && !active.containsKey(it.id) && (it.nextRetryAt ?: 0) <= now() }.sortedBy { it.order }
        // Admission remains durable and pending until Android acknowledges a
        // foreground worker. An OS-denied start never looks like a transfer.
        if (candidates.isNotEmpty() && !requestWorker()) { notifyWork(); return }
        for (record in candidates) {
            if (active.size >= maxParallel) break
            record.state = State.DOWNLOADING; record.nextRetryAt = null; record.error = null; save(record)
            val current = ++token
            try {
                if (record.retryCount > 0) engine.prepareRetry(record)
                val transfer = engine.start(record.copy(), { progress ->
                    actor.execute {
                        if (active[record.id]?.token == current) {
                            active[record.id]?.rate?.record(progress.received, monotonic())
                            val fraction = maxOf(record.progress, progress.fraction.takeIf { it.isFinite() }?.coerceIn(0.0, 0.999999) ?: 0.0)
                            if (record.progress != fraction || record.received != progress.received || record.total != progress.total) {
                                record.progress = fraction; record.received = progress.received; record.total = progress.total
                                dirtyProgress.add(record.id)
                            }
                        }
                    }
                }, { outcome -> actor.execute { finish(record, current, outcome) } })
                active[record.id] = Running(current, transfer).also { it.rate.record(record.received, monotonic()) }
            } catch (error: Throwable) {
                failed(record, failure(error))
            }
        }
        rescheduleIfNeeded()
    }

    private fun stop(id: String, reason: Stop) {
        val running = active[id] ?: return
        if (running.stop == Stop.CANCEL) return
        // User pause takes priority over config/disable holds. Cancel wins all.
        if (running.stop == Stop.PAUSE && reason != Stop.CANCEL) return
        // A service interruption or parallelism change must not undo disable.
        if (running.stop == Stop.DISABLE && reason in setOf(Stop.LIMIT, Stop.NETWORK)) return
        running.stop = reason
        val record = records.getValue(id)
        record.stopIntent = reason.name
        record.disableHeld = reason == Stop.DISABLE
        record.state = if (reason == Stop.PAUSE || reason == Stop.DISABLE) State.PAUSED else State.PENDING
        save(record)
        running.transfer.stop()
    }

    private fun cancel(id: String) {
        val record = records[id] ?: return
        if (!record.state.unfinished) return
        if (active.containsKey(id)) stop(id, Stop.CANCEL) else remove(record, true)
    }

    private fun remove(record: Record, emitEnd: Boolean) {
        if (record.id in licensing) throw DownloadFailure("E_BUSY", "Wait for the license operation to finish.", true)
        // Engine checks playback leases before deleting. On failure, metadata
        // stays visible and the promise rejects; nothing is silently swallowed.
        engine.delete(record) { record.stopIntent = "DELETE"; save(record) }
        try { store.remove(record.id) } catch (error: Throwable) { halt(error); throw fault!! }
        record.state = State.REMOVED; record.asset = null; record.error = null; record.stopIntent = null
        if (emitEnd) event("onDownloadEnd", status(record))
    }

    private fun finish(record: Record, current: Long, outcome: TransferResult) {
        val running = active[record.id]?.takeIf { it.token == current } ?: return
        active.remove(record.id)
        try {
            record.stopIntent = null
            if (running.stop != null && running.stop != Stop.CANCEL && outcome is TransferResult.Failed && !(running.stop == Stop.NETWORK && outcome.error.retryable)) throw outcome.error
            when (running.stop) {
                Stop.CANCEL -> remove(record, true)
                Stop.PAUSE -> { record.state = State.PAUSED; save(record) }
                Stop.DISABLE -> { record.state = if (enabled && !record.disableHeld) State.PENDING else State.PAUSED; save(record) }
                Stop.LIMIT, Stop.NETWORK -> { record.state = State.PENDING; save(record) }
                null -> when (outcome) {
                    is TransferResult.Complete -> {
                        record.asset = outcome.asset; record.progress = 1.0; record.state = State.COMPLETED
                        record.received = outcome.received; record.total = outcome.total
                        save(record); event("onDownloadEnd", status(record))
                    }
                    is TransferResult.Failed -> {
                        failed(record, outcome.error)
                    }
                    TransferResult.Stopped -> throw DownloadFailure("E_ENGINE", "Transfer stopped without a queue request.")
                }
            }
            checkBarriers(); pump(); rescheduleIfNeeded()
        } catch (error: Throwable) {
            // Do not report completion after a failed durable commit. Halt new
            // work and surface the persistence/cleanup failure for recovery.
            halt(error)
        }
    }

    private fun configuration(): Map<String, Any?> = policy.wire() + mapOf("maxParallelDownloads" to maxParallel, "updateFrequencyMS" to frequency)
    private fun loadConfiguration() {
        if (configurationLoaded) return
        val config = store.configuration(); policy = policy.updated(config)
        maxParallel = (config["maxParallelDownloads"] as? Number)?.toInt() ?: maxParallel
        frequency = (config["updateFrequencyMS"] as? Number)?.toLong() ?: frequency
        engine.setWifiOnly(policy.wifiOnly); configurationLoaded = true
    }
    private fun status(record: Record): Map<String, Any?> = record.status().toMutableMap().apply {
        if (record.state == State.PENDING && !networkAllowed) put("waitingForNetwork", true)
        active[record.id]?.takeIf { record.state == State.DOWNLOADING && it.stop == null }?.rate?.rate(monotonic())?.let { rate ->
            put("bytesPerSecond", rate)
            val remaining = record.total?.let { total -> record.received?.let { (total - it).coerceAtLeast(0) } }
            if (rate > 0 && remaining != null) put("estimatedRemainingSeconds", remaining / rate)
        }
    }
    private fun failed(record: Record, error: DownloadFailure) {
        if (error.code == "E_NETWORK_POLICY") { record.state = State.PENDING; record.error = null; save(record); return }
        val transient = error.retryable && error.code in setOf("E_NETWORK", "E_DRM_LICENSE_REQUEST", "E_DRM_PROVISIONING")
        if (transient && record.retryCount < policy.maxRetries) {
            record.retryCount++; record.nextRetryAt = now() + policy.retryDelay(record.retryCount)
            record.state = State.PENDING; record.error = error.message; save(record)
        } else {
            record.state = State.FAILED; record.nextRetryAt = null; record.error = error.message; save(record)
            engine.delete(record); event("onError", record.error!!); event("onDownloadEnd", status(record))
        }
    }
    private fun scheduleRetry() {
        retryTimer?.cancel(false); retryTimer = null
        if (!enabled || fault != null || !networkAllowed || active.size >= maxParallel) return
        val due = records.values.filter { it.state == State.PENDING && !active.containsKey(it.id) }.mapNotNull { it.nextRetryAt }.minOrNull() ?: return
        // A deadline can pass between pump and scheduling; still arrange a wakeup.
        // If Android denied a worker, its readiness callback will resume the queue.
        if (due <= now() && !requestWorker()) return
        retryTimer = actor.schedule({ try { pump(); rescheduleIfNeeded() } catch (error: Throwable) { halt(error) } }, (due - now()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
    }
    private fun license(record: Record, renew: Boolean, params: Map<String, Any?>, result: CompletableFuture<Any?>) {
        if (renew && !networkAllowed) throw DownloadFailure("E_NETWORK_POLICY", "Connect to an allowed network before renewing rights.", true)
        if (!licensing.add(record.id)) throw DownloadFailure("E_BUSY", "A license operation is already running for this asset.", true)
        @Suppress("UNCHECKED_CAST") val config = params["drm"] as? Map<String, Any?>
        try {
            engine.license(record.copy(), renew, config).whenComplete { update, error -> actor.execute {
                try {
                    if (error != null) throw (error.cause ?: error)
                    if (renew) {
                        update.asset?.let { record.asset = it }
                        if (config != null) record.options = record.options + ("drm" to config)
                        save(record)
                    }
                    result.complete(update.status)
                } catch (failure: Throwable) { result.completeExceptionally(failure) }
                finally { update?.release?.invoke(); licensing.remove(record.id); checkBarriers() }
            } }
        } catch (error: Throwable) { licensing.remove(record.id); throw error }
    }

    private fun barrier(future: CompletableFuture<Any?>, ready: () -> Boolean, value: Any?) {
        if (ready()) future.complete(value) else barriers.add(Barrier(future, ready, value))
    }
    private fun checkBarriers() {
        val completed = barriers.filter { it.ready() }
        barriers.removeAll(completed.toSet()); completed.forEach { it.future.complete(it.value) }
    }
    private fun rescheduleIfNeeded() {
        scheduleRetry(); notifyWork()
        val needed = progressEnabled && records.values.any { it.state.unfinished }
        if (needed && timer == null) reschedule()
        else if (!needed) { timer?.cancel(false); timer = null }
    }
    private fun reschedule() {
        timer?.cancel(false); timer = null
        if (progressEnabled && records.values.any { it.state.unfinished }) {
            timer = actor.scheduleWithFixedDelay({
                try { persistProgress(); event("onDownloadProgress", records.values.map(::status)) }
                catch (error: Throwable) { halt(error) }
            }, frequency, frequency, TimeUnit.MILLISECONDS)
        }
    }
    private fun failure(error: Throwable): DownloadFailure = error as? DownloadFailure
        ?: DownloadFailure("E_STORAGE", "Native storage or transfer operation failed.")
    private fun persistProgress(id: String) {
        if (id in dirtyProgress && id in active) records[id]?.let(::save)
    }
    // Publish only durable progress, without rewriting unchanged rows on polls.
    private fun persistProgress() { dirtyProgress.toList().forEach(::persistProgress) }
    private fun notifyWork() { workChanged(fault == null && (active.isNotEmpty() || enabled && records.values.any { it.state == State.PENDING })) }
    private fun halt(error: Throwable) {
        if (fault != null) return
        fault = failure(error); enabled = false; playbackEnabled(false)
        timer?.cancel(false); timer = null; retryTimer?.cancel(false); retryTimer = null
        active.values.forEach { it.transfer.stop() }
        barriers.forEach { it.future.completeExceptionally(fault!!) }; barriers.clear()
        event("onError", fault!!.message ?: "Native storage failed.")
        notifyWork()
    }
}
