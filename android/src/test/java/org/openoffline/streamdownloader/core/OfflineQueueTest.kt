package org.openoffline.streamdownloader.core

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class OfflineQueueTest {
    private class MemoryStore : Store {
        val rows = linkedMapOf<String, Record>()
        var enabledValue = false
        var failWrites = false
        var failRemoves = false
        var writes = 0
        var config: Map<String, Any?> = emptyMap()
        override fun configuration() = config
        override fun setConfiguration(value: Map<String, Any?>) { config = value }
        override fun load(): List<Record> = rows.values.map { it.copy() }
        override fun put(record: Record) { if (failWrites) throw IllegalStateException("disk failure"); rows[record.id] = record.copy(); writes++ }
        override fun remove(id: String) { if (failRemoves) throw IllegalStateException("delete failure"); rows.remove(id) }
        override fun enabled(): Boolean = enabledValue
        override fun setEnabled(enabled: Boolean) { enabledValue = enabled }
    }
    private class ControlledEngine : Engine {
        data class Task(val record: Record, val progress: (TransferProgress) -> Unit, val finish: (TransferResult) -> Unit, var stopped: Boolean = false)
        val tasks = CopyOnWriteArrayList<Task>()
        val deleted = CopyOnWriteArrayList<String>()
        var valid = true
        var failDeletes = false
        var retriesPrepared = 0
        @Volatile var onStart: (() -> Unit)? = null
        var licenseResult = CompletableFuture<LicenseUpdate>()
        override fun prepareRetry(record: Record) { retriesPrepared++ }
        override fun license(record: Record, renew: Boolean, config: Map<String, Any?>?) = licenseResult
        override fun start(record: Record, progress: (TransferProgress) -> Unit, finished: (TransferResult) -> Unit): Transfer {
            val task = Task(record, progress, finished); tasks.add(task); onStart?.invoke()
            return Transfer { task.stopped = true }
        }
        override fun delete(record: Record) { if (failDeletes) throw DownloadFailure("E_STORAGE", "Cleanup failed."); deleted.add(record.id) }
        override fun valid(record: Record): Boolean = valid
        fun latest(id: String): Task = tasks.last { it.record.id == id }
        fun complete(id: String) { latest(id).finish(TransferResult.Complete(Asset("rnv-offline://asset/$id/video.mp4", 2000, 100), 100, 100)) }
        fun stopped(id: String) { latest(id).finish(TransferResult.Stopped) }
    }
    private lateinit var store: MemoryStore
    private lateinit var engine: ControlledEngine
    private lateinit var queue: OfflineQueue
    private val events = CopyOnWriteArrayList<Pair<String, Any>>()
    @Before fun setup() { store = MemoryStore(); engine = ControlledEngine(); queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) }); run("registerPlugin") }
    @After fun cleanup() {
        // Acknowledge the controlled transfers before shutting down the actor.
        val cancel = queue.execute("cancelAllDownloads", emptyMap())
        runCatching { run("getDownloadsStatus") }
        engine.tasks.filter { it.stopped }.forEach { it.finish(TransferResult.Stopped) }
        runCatching { cancel.get(2, TimeUnit.SECONDS) }
        runCatching { queue.close().get(2, TimeUnit.SECONDS) }
    }
    private fun run(method: String, params: Map<String, Any?> = emptyMap()): Any? = queue.execute(method, params).get(2, TimeUnit.SECONDS)
    private fun limit(value: Int) { run("setConfig", mapOf("config" to mapOf("maxParallelDownloads" to value))) }
    private fun admit(key: String): String {
        val admitted = run("downloadStream", mapOf("url" to "https://media.test/$key.mp4", "options" to emptyMap<String, Any?>(), "fingerprint" to key)) as Map<*, *>
        run("getDownloadsStatus") // actor barrier after admission's pump
        return admitted["id"] as String
    }
    private fun state(id: String): String? = (run("getDownloadStatus", mapOf("id" to id)) as? Map<*, *>)?.get("status") as? String

    @Test fun fifoStartsOnlyAllowedNumberAndFillsFreedSlots() {
        limit(2)
        val a = admit("a"); val b = admit("b"); val c = admit("c")
        assertEquals(listOf(a, b), engine.tasks.map { it.record.id }); assertEquals("pending", state(c))
        engine.complete(a)
        assertEquals("completed", state(a)); assertEquals("downloading", state(c))
        assertEquals(listOf(a, b, c), engine.tasks.map { it.record.id })
        assertEquals(State.COMPLETED, store.rows[a]?.state)
        assertEquals("onDownloadEnd", events.first().first)
    }

    @Test fun backgroundRecoveryWaitsForWorkerAndPreservesUserPause() {
        queue.close().get(2, TimeUnit.SECONDS)
        store.rows["pending"] = Record("pending", "https://media.test/p.mp4", emptyMap(), "p", 1)
        store.rows["paused"] = Record("paused", "https://media.test/q.mp4", emptyMap(), "q", 2, state = State.PAUSED)
        store.enabledValue = true
        val ready = AtomicBoolean(false)
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) }, requestWorker = ready::get)
        queue.restoreBackground()
        assertEquals("pending", state("pending")); assertTrue(engine.tasks.isEmpty())
        ready.set(true); queue.workerReady()
        assertEquals("downloading", state("pending")); assertEquals("paused", state("paused"))
        ready.set(false); queue.workerUnavailable("Android stopped the worker.")
        assertEquals("pending", state("pending")); assertTrue(engine.latest("pending").stopped)
        engine.stopped("pending"); state("pending")
        assertEquals(1, engine.tasks.size)
        ready.set(true); queue.workerReady()
        assertEquals("downloading", state("pending")); assertEquals(2, engine.tasks.size)
        assertEquals("paused", state("paused"))
    }

    @Test fun backgroundRestoreDoesNotUndoExplicitDisable() {
        queue.close().get(2, TimeUnit.SECONDS)
        store.rows["pending"] = Record("pending", "https://media.test/p.mp4", emptyMap(), "p", 1)
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) })
        queue.restoreBackground()
        assertTrue(runCatching { run("getDownloadsStatus") }.isFailure)
        assertTrue(engine.tasks.isEmpty()); assertFalse(store.enabledValue)
        run("registerPlugin")
        assertEquals("downloading", state("pending"))
    }

    @Test fun configurationBeforeRegistrationDoesNotEnableWork() {
        queue.close().get(2, TimeUnit.SECONDS)
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) })
        run("setConfig", mapOf("config" to mapOf("maxParallelDownloads" to 2)))
        assertEquals(2, (run("getConfig") as Map<*, *>)["maxParallelDownloads"])
        assertFalse(store.enabledValue); assertTrue(engine.tasks.isEmpty())
        assertTrue(runCatching { admit("not-registered") }.isFailure)
        run("registerPlugin")
        assertEquals(2, (run("getConfig") as Map<*, *>)["maxParallelDownloads"])
    }

    @Test fun pauseWaitsForNativeStopAndDoesNotAutoResume() {
        limit(1); val a = admit("a"); val b = admit("b")
        val pause = queue.execute("pauseDownload", mapOf("id" to a))
        state(a); assertTrue(engine.latest(a).stopped); assertFalse(pause.isDone)
        assertEquals(1, engine.tasks.size)
        engine.stopped(a); pause.get(2, TimeUnit.SECONDS)
        assertEquals("paused", state(a)); assertEquals("downloading", state(b))
        run("resumeDownload", mapOf("id" to a)); assertEquals("pending", state(a))
        engine.complete(b); assertEquals("downloading", state(a)); assertEquals(2, engine.tasks.count { it.record.id == a })
        assertEquals(1, events.count { it.first == "onDownloadEnd" })
    }

    @Test fun reducingLimitWaitsForSurplusAndPreservesUserPause() {
        limit(3); val a = admit("a"); val b = admit("b"); val c = admit("c")
        val config = queue.execute("setConfig", mapOf("config" to mapOf("maxParallelDownloads" to 1)))
        state(a); assertFalse(config.isDone); assertFalse(engine.latest(a).stopped)
        assertTrue(engine.latest(b).stopped); assertTrue(engine.latest(c).stopped)
        val pause = queue.execute("pauseDownload", mapOf("id" to b)); state(b)
        engine.stopped(b); engine.stopped(c)
        config.get(2, TimeUnit.SECONDS); pause.get(2, TimeUnit.SECONDS)
        assertEquals("paused", state(b)); assertEquals("pending", state(c))
        engine.complete(a); assertEquals("downloading", state(c)); assertEquals("paused", state(b))
    }

    @Test fun cancellationWinsOverConcurrentCompletionAndLateCallbacks() {
        limit(1); val a = admit("a"); val task = engine.latest(a)
        val cancel = queue.execute("cancelDownload", mapOf("id" to a)); state(a)
        assertFalse(cancel.isDone)
        engine.complete(a); cancel.get(2, TimeUnit.SECONDS)
        assertEquals("removed", state(a)); assertFalse(store.rows.containsKey(a))
        task.finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "late failure")))
        task.progress(TransferProgress(0.7, 70, 100)); state(a)
        assertEquals(1, events.size); assertEquals("onDownloadEnd", events[0].first)
        assertEquals("removed", (events[0].second as Map<*, *>)["status"])
    }

    @Test fun failureEmitsErrorThenTerminalAndStartsNextJob() {
        limit(1); val a = admit("a"); val b = admit("b")
        engine.latest(a).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Network transfer failed.", true)))
        assertEquals("failed", state(a)); assertEquals("downloading", state(b))
        assertEquals(listOf("onError", "onDownloadEnd"), events.map { it.first })
        assertTrue(engine.deleted.contains(a)); assertEquals(State.FAILED, store.rows[a]?.state)
    }

    @Test fun deduplicationOnlyReusesUnfinishedEquivalentRequests() {
        val a = admit("same"); assertEquals(a, admit("same")); assertEquals(1, engine.tasks.size)
        val different = admit("different-entitlement"); assertNotEquals(a, different)
        engine.complete(a); state(a)
        assertNotEquals(a, admit("same"))
    }

    @Test fun disableWaitsAndRegistrationResumesHeldButNotUserPaused() {
        limit(1); val a = admit("a"); val b = admit("b"); val c = admit("c")
        run("pauseDownload", mapOf("id" to c))
        val disable = queue.execute("disablePlugin", emptyMap())
        queue.execute("registerPlugin", emptyMap()) // queued registration models sequential actor requests
        // Use the persisted stop intent as acknowledgement that disable ran.
        run("getDownloadsStatus")
        assertTrue(engine.latest(a).stopped); assertFalse(disable.isDone)
        engine.stopped(a); disable.get(2, TimeUnit.SECONDS)
        assertEquals("paused", state(c))
        assertTrue(state(a) == "downloading" || state(b) == "downloading")
    }

    @Test fun completedDeletionDoesNotEmitAnotherEndAndCorruptionRejectsLookup() {
        val a = admit("a"); engine.complete(a); state(a)
        assertEquals(1, (run("getDownloadedAssets") as List<*>).size)
        engine.valid = false
        val failure = runCatching { run("getDownloadedAsset", mapOf("id" to a)) }.exceptionOrNull()
        assertTrue(failure?.cause is DownloadFailure)
        engine.valid = true
        run("deleteDownloadedAsset", mapOf("id" to a)); assertNull(run("getDownloadedAsset", mapOf("id" to a)))
        assertEquals(1, events.count { it.first == "onDownloadEnd" })
    }

    @Test fun nativeProgressDoesNotReportCompletionBeforeDurableCommit() {
        val a = admit("a")
        engine.latest(a).progress(TransferProgress(1.0, 100, 100))
        val current = run("getDownloadStatus", mapOf("id" to a)) as Map<*, *>
        assertTrue((current["progress"] as Double) < 1)
        assertEquals("downloading", current["status"])
        assertTrue(events.isEmpty())
        engine.latest(a).progress(TransferProgress(0.1, 10, 100))
        assertEquals(current["progress"], (run("getDownloadStatus", mapOf("id" to a)) as Map<*, *>)["progress"])
        engine.complete(a); state(a)
        assertEquals(1.0, (events.single().second as Map<*, *>)["progress"])
    }

    @Test fun unchangedProgressPollsDoNotRewriteStorageButByteChangesAreCommitted() {
        val id = admit("progress")
        val initialWrites = store.writes
        repeat(100) { state(id); run("getDownloadsStatus") }
        assertEquals(initialWrites, store.writes)

        engine.latest(id).progress(TransferProgress(0.25, 25, 100))
        state(id)
        assertEquals(initialWrites + 1, store.writes)
        assertEquals(0.25, store.rows[id]!!.progress, 0.0)
        repeat(100) {
            engine.latest(id).progress(TransferProgress(0.25, 25, 100))
            run("getDownloadsStatus")
        }
        assertEquals(initialWrites + 1, store.writes)

        engine.latest(id).progress(TransferProgress(0.25, 30, null))
        run("getDownloadsStatus")
        assertEquals(initialWrites + 2, store.writes)
        assertEquals(30L, store.rows[id]?.received)
        assertNull(store.rows[id]?.total)
        engine.complete(id); state(id)
        assertEquals(State.COMPLETED, store.rows[id]?.state)
        assertEquals(initialWrites + 3, store.writes)
    }

    @Test fun duplicateAdmissionPersistsProgressBeforeReturningIt() {
        val id = admit("duplicate")
        engine.latest(id).progress(TransferProgress(0.5, 50, 100))
        val result = run("downloadStream", mapOf("url" to "https://media.test/duplicate.mp4", "options" to emptyMap<String, Any?>(), "fingerprint" to "duplicate")) as Map<*, *>
        assertEquals(id, result["id"])
        assertEquals(0.5, result["progress"])
        assertEquals(result["progress"], store.rows[id]?.progress)
    }

    @Test fun failedProgressCommitRejectsStatusAndStopsTheTransfer() {
        val id = admit("progress-failure")
        engine.latest(id).progress(TransferProgress(0.5, 50, 100))
        store.failWrites = true
        val error = runCatching { state(id) }.exceptionOrNull()
        assertEquals("E_STORAGE", (error?.cause as? DownloadFailure)?.code)
        assertEquals(0.0, store.rows[id]!!.progress, 0.0)
        assertTrue(engine.latest(id).stopped)
        assertEquals(listOf("onError"), events.map { it.first })
        store.failWrites = false
    }

    @Test fun startupRecoversStopIntentWithoutRestartingACancelledTransfer() {
        queue.close().get(2, TimeUnit.SECONDS)
        val cancelled = Record("cancelled", "https://media.test/c.mp4", emptyMap(), "c", 1, stopIntent = "CANCEL")
        val paused = Record("paused", "https://media.test/p.mp4", emptyMap(), "p", 2, state = State.PAUSED, stopIntent = "PAUSE")
        val expired = Record("expired", "https://media.test/e.mp4", emptyMap(), "e", 3, state = State.COMPLETED, asset = Asset("local", 0, 0), expiresAt = 1)
        store.rows[cancelled.id] = cancelled; store.rows[paused.id] = paused; store.rows[expired.id] = expired
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) }, now = { 100 })
        run("registerPlugin")
        assertNull(state("cancelled")); assertEquals("paused", state("paused")); assertEquals("removed", state("expired"))
        assertTrue(engine.tasks.isEmpty()); assertTrue(engine.deleted.containsAll(listOf("cancelled", "expired")))
        assertTrue(events.isEmpty())
    }

    @Test fun failedCompletionCommitNeverEmitsSuccess() {
        val a = admit("a"); store.failWrites = true
        engine.complete(a)
        val error = runCatching { state(a) }.exceptionOrNull()
        assertEquals("E_STORAGE", (error?.cause as? DownloadFailure)?.code)
        assertEquals(listOf("onError"), events.map { it.first })
        assertEquals(State.DOWNLOADING, store.rows[a]?.state)
        store.failWrites = false
    }
    @Test fun deletionIntentSurvivesFailureBetweenMediaRemovalAndMetadataCommit() {
        val id = admit("remove"); engine.complete(id); state(id)
        store.failRemoves = true
        assertTrue(runCatching { run("deleteDownloadedAsset", mapOf("id" to id)) }.isFailure)
        assertEquals("DELETE", store.rows[id]?.stopIntent); assertTrue(engine.deleted.contains(id))
        runCatching { queue.close().get(2, TimeUnit.SECONDS) }
        store.failRemoves = false
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) })
        run("registerPlugin")
        assertNull(state(id)); assertFalse(store.rows.containsKey(id))
        assertEquals(1, events.count { it.first == "onDownloadEnd" })
    }
    @Test fun failedCleanupDoesNotTurnFailedDownloadIntoAutomaticRetryAfterRestart() {
        val id = admit("failure"); engine.failDeletes = true
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Network failed.")))
        assertTrue(runCatching { state(id) }.isFailure)
        assertEquals(State.FAILED, store.rows[id]?.state)
        runCatching { queue.close().get(2, TimeUnit.SECONDS) }; engine.failDeletes = false
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) })
        run("registerPlugin")
        assertEquals("failed", state(id)); assertEquals(1, engine.tasks.size)
    }
    @Test fun retryBackoffIsDurableBoundedAndEmitsOnlyTheFinalFailure() {
        queue.close().get(2, TimeUnit.SECONDS)
        val clock = java.util.concurrent.atomic.AtomicLong(1000)
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) }, now = clock::get)
        run("setConfig", mapOf("config" to mapOf("retry" to mapOf("maxRetries" to 2, "initialDelayMS" to 60000, "maxDelayMS" to 120000))))
        run("registerPlugin"); val id = admit("retry")
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Temporary network failure.", true)))
        assertEquals("pending", state(id)); assertEquals(61000L, store.rows[id]?.nextRetryAt)
        assertTrue(events.isEmpty()); assertEquals(1, engine.tasks.size)
        clock.set(61000); queue.workerReady(); assertEquals("downloading", state(id))
        assertEquals(1, engine.retriesPrepared)
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Temporary network failure.", true)))
        assertEquals("pending", state(id)); assertEquals(181000L, store.rows[id]?.nextRetryAt)
        clock.set(181000); queue.workerReady(); assertEquals("downloading", state(id))
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Temporary network failure.", true)))
        assertEquals("failed", state(id)); assertEquals(3, engine.tasks.size)
        assertEquals(listOf("onError", "onDownloadEnd"), events.map { it.first })
    }

    @Test fun denialIsNeverAutomaticallyRetried() {
        run("setConfig", mapOf("config" to mapOf("retry" to mapOf("maxRetries" to 3))))
        val id = admit("denied")
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_DRM_LICENSE_DENIED", "Denied.", true)))
        assertEquals("failed", state(id)); assertEquals(1, engine.tasks.size)
    }

    @Test fun retryTimerRunsWithoutProgressListenersOrPolling() {
        run("setConfig", mapOf("config" to mapOf("retry" to mapOf("maxRetries" to 1, "initialDelayMS" to 100))))
        val id = admit("timer")
        val restarted = java.util.concurrent.CountDownLatch(1)
        engine.onStart = { restarted.countDown() }
        engine.latest(id).finish(TransferResult.Failed(DownloadFailure("E_NETWORK", "Temporary failure.", true)))
        assertTrue(restarted.await(3, TimeUnit.SECONDS))
        assertEquals("downloading", state(id)); assertEquals(2, engine.tasks.size); assertTrue(events.isEmpty())
    }

    @Test fun wifiWaitsStopsOnLossAndDoesNotUndoUserPause() {
        run("setConfig", mapOf("config" to mapOf("wifiOnly" to true)))
        val id = admit("wifi")
        assertTrue(engine.tasks.isEmpty())
        assertEquals(true, (run("getDownloadStatus", mapOf("id" to id)) as Map<*, *>)["waitingForNetwork"])
        queue.setNetworkState(true, true); assertEquals("downloading", state(id))
        queue.setNetworkState(true, false); assertEquals("pending", state(id)); assertTrue(engine.latest(id).stopped)
        engine.stopped(id); state(id); assertEquals(1, engine.tasks.size)
        run("pauseDownload", mapOf("id" to id))
        queue.setNetworkState(true, true); assertEquals("paused", state(id)); assertEquals(1, engine.tasks.size)
        run("resumeDownload", mapOf("id" to id)); assertEquals("downloading", state(id))
    }

    @Test fun wifiPolicyAndLimitChangeWaitForEveryOldTransfer() {
        queue.setNetworkState(true, true)
        val first = admit("first"); val second = admit("second")
        val configured = queue.execute("setConfig", mapOf("config" to mapOf("wifiOnly" to true, "maxParallelDownloads" to 1)))
        run("getConfig")
        assertTrue(engine.latest(first).stopped); assertTrue(engine.latest(second).stopped)
        engine.stopped(first); run("getConfig"); assertFalse(configured.isDone)
        engine.stopped(second); configured.get(2, TimeUnit.SECONDS)
        assertEquals("downloading", state(first)); assertEquals("pending", state(second))
    }

    @Test fun policySurvivesAQueueRestart() {
        run("setConfig", mapOf("config" to mapOf("wifiOnly" to true, "retry" to mapOf("maxRetries" to 2))))
        queue.close().get(2, TimeUnit.SECONDS)
        queue = OfflineQueue(store, engine, { name, payload -> events.add(name to payload) })
        val config = run("getConfig") as Map<*, *>
        assertEquals(true, config["wifiOnly"]); assertEquals(2, (config["retry"] as Map<*, *>)["maxRetries"])
    }

    @Test fun licenseMaintenanceBlocksDeletionAndDisableWaitsForCommit() {
        val id = admit("license"); engine.complete(id); state(id)
        val renewal = queue.execute("renewDRMLicense", mapOf("id" to id)); state(id)
        assertTrue(runCatching { run("deleteDownloadedAsset", mapOf("id" to id)) }.isFailure)
        val disable = queue.execute("disablePlugin", emptyMap())
        run("getConfig"); assertFalse(disable.isDone)
        val released = AtomicBoolean(false)
        engine.licenseResult.complete(LicenseUpdate(mapOf("id" to id, "scheme" to "widevine", "state" to "valid", "checkedAt" to 1L), store.rows[id]?.asset) { released.set(true) })
        renewal.get(2, TimeUnit.SECONDS); disable.get(2, TimeUnit.SECONDS)
        assertTrue(released.get()); assertEquals(State.COMPLETED, store.rows[id]?.state)
    }

    @Test fun speedSamplesResetAcrossRestartsAndExpireWhenStalled() {
        val rate = TransferRate()
        rate.record(0, 0); rate.record(1000, 1000)
        assertEquals(1000.0, rate.rate(1000)!!, 0.0)
        assertEquals(0.0, rate.rate(5000)!!, 0.0)
        rate.record(10, 5001); assertNull(rate.rate(5001))
        rate.record(null, 6000); assertNull(rate.rate(6000))
    }

}
