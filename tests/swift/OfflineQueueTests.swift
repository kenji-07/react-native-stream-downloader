import Foundation
import XCTest
@testable import StreamDownloaderCore

final class OfflineQueueTests: XCTestCase {
    final class MemoryStore: RecordStore {
        var rows: [String: DownloadRecord] = [:]
        var failWrites = false
        var failRemoves = false
        var enabledValue = false
        var config: [String: JSONValue] = [:]
        func configuration() throws -> [String: JSONValue] { config }
        func setConfiguration(_ value: [String: JSONValue]) throws { config = value }
        func load() throws -> [DownloadRecord] { Array(rows.values) }
        func put(_ record: DownloadRecord) throws {
            if failWrites { throw OfflineError(code: "E_STORAGE", message: "Storage write failed.") }
            rows[record.id] = record
        }
        func remove(_ id: String) throws {
            if failRemoves { throw OfflineError(code: "E_STORAGE", message: "Metadata removal failed.") }
            rows.removeValue(forKey: id)
        }
        func setEnabled(_ enabled: Bool) throws { enabledValue = enabled }
        func enabled() throws -> Bool { enabledValue }
    }
    final class ControlledEngine: MediaEngine {
        final class Transfer: MediaTransfer {
            let record: DownloadRecord
            let progress: (TransferProgress) -> Void
            let finished: (TransferResult) -> Void
            var stopped = false
            init(_ record: DownloadRecord, _ progress: @escaping (TransferProgress) -> Void, _ finished: @escaping (TransferResult) -> Void) { self.record = record; self.progress = progress; self.finished = finished }
            func stop() { stopped = true }
        }
        var tasks: [Transfer] = []
        var deleted: [String] = []
        var failDeletes = false
        var retriesPrepared = 0
        var onStart: (() -> Void)?
        var licenseCompletion: ((Result<LicenseUpdate, Error>) -> Void)?
        func prepareRetry(_ record: DownloadRecord) throws { retriesPrepared += 1 }
        func license(_ record: DownloadRecord, renew: Bool, config: [String: JSONValue]?, completion: @escaping (Result<LicenseUpdate, Error>) -> Void) { licenseCompletion = completion }
        func start(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
            let task = Transfer(record, progress, finished); tasks.append(task); onStart?(); return task
        }
        func delete(_ record: DownloadRecord) throws {
            if failDeletes { throw OfflineError(code: "E_STORAGE", message: "Cleanup failed.") }
            deleted.append(record.id)
        }
        func valid(_ record: DownloadRecord) -> Bool { record.asset != nil }
        func latest(_ id: String) -> Transfer { tasks.last { $0.record.id == id }! }
        func complete(_ id: String) { latest(id).finished(.complete(OfflineAsset(path: "file:///test/\(id).mp4", duration: 2000, date: 100), 100, 100)) }
    }
    private var store: MemoryStore!
    private var engine: ControlledEngine!
    private var queue: OfflineQueue!
    private var events: [(String, Any)] = []
    override func setUpWithError() throws {
        store = MemoryStore(); engine = ControlledEngine()
        queue = OfflineQueue(store: store, engine: engine) { [weak self] name, payload in self?.events.append((name, payload)) }
        _ = try run("registerPlugin")
    }
    private func run(_ method: String, _ params: [String: JSONValue] = [:]) throws -> Any? {
        let expectation = expectation(description: method)
        var result: Result<Any?, Error>!
        queue.execute(method, params) { result = $0; expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(result).get()
    }
    private func limit(_ value: Double) throws { _ = try run("setConfig", ["config": .object(["maxParallelDownloads": .number(value)])]) }
    private func admit(_ key: String) throws -> String {
        let result = try run("downloadStream", ["url": .string("https://media.test/\(key).mp4"), "options": .object([:]), "fingerprint": .string(key)]) as! [String: Any]
        _ = try run("getDownloadsStatus")
        return result["id"] as! String
    }
    private func state(_ id: String) throws -> String? { (try run("getDownloadStatus", ["id": .string(id)]) as? [String: Any])?["status"] as? String }

    func testConcurrencyFIFOAndCommittedTerminal() throws {
        try limit(2); let a = try admit("a"); let b = try admit("b"); let c = try admit("c")
        XCTAssertEqual(engine.tasks.map { $0.record.id }, [a, b]); XCTAssertEqual(try state(c), "pending")
        engine.complete(a); XCTAssertEqual(try state(a), "completed"); XCTAssertEqual(try state(c), "downloading")
        XCTAssertEqual(store.rows[a]?.state, .completed); XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].0, "onDownloadEnd")
    }
    func testPauseWaitsForTransferAcknowledgement() throws {
        try limit(1); let a = try admit("a"); let b = try admit("b")
        let paused = expectation(description: "paused")
        var acknowledged = false
        queue.execute("pauseDownload", ["id": .string(a)]) { _ in acknowledged = true; paused.fulfill() }
        _ = try state(a); XCTAssertTrue(engine.latest(a).stopped); XCTAssertFalse(acknowledged)
        XCTAssertEqual(engine.tasks.count, 1)
        engine.latest(a).finished(.stopped); wait(for: [paused], timeout: 2)
        XCTAssertEqual(try state(a), "paused"); XCTAssertEqual(try state(b), "downloading")
        _ = try run("resumeDownload", ["id": .string(a)]); engine.complete(b)
        XCTAssertEqual(try state(a), "downloading"); XCTAssertEqual(engine.tasks.filter { $0.record.id == a }.count, 2)
    }
    func testLimitReductionAndUserPauseHaveDistinctIntent() throws {
        try limit(3); let a = try admit("a"); let b = try admit("b"); let c = try admit("c")
        let reconfigured = expectation(description: "reconfigured"); let paused = expectation(description: "paused")
        var done = false
        queue.execute("setConfig", ["config": .object(["maxParallelDownloads": .number(1)])]) { _ in done = true; reconfigured.fulfill() }
        _ = try state(a); XCTAssertFalse(done); XCTAssertFalse(engine.latest(a).stopped)
        queue.execute("pauseDownload", ["id": .string(b)]) { _ in paused.fulfill() }
        _ = try state(b); engine.latest(b).finished(.stopped); engine.latest(c).finished(.stopped)
        wait(for: [reconfigured, paused], timeout: 2)
        XCTAssertEqual(try state(b), "paused"); XCTAssertEqual(try state(c), "pending")
        engine.complete(a); XCTAssertEqual(try state(c), "downloading")
    }
    func testCancellationWinsCompletionAndStaleCallbacks() throws {
        let a = try admit("a"); let task = engine.latest(a)
        let cancelled = expectation(description: "cancelled")
        queue.execute("cancelDownload", ["id": .string(a)]) { _ in cancelled.fulfill() }
        _ = try state(a); engine.complete(a); wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(try state(a), "removed"); XCTAssertNil(store.rows[a])
        task.finished(.failed(OfflineError(code: "E_NETWORK", message: "late"))); task.progress(TransferProgress(fraction: 0.9, received: 90, total: 100))
        _ = try state(a); XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].0, "onDownloadEnd")
    }
    func testFailureOrderAndNextJob() throws {
        try limit(1); let a = try admit("a"); let b = try admit("b")
        engine.latest(a).finished(.failed(OfflineError(code: "E_NETWORK", message: "Network transfer failed.")))
        XCTAssertEqual(try state(a), "failed"); XCTAssertEqual(try state(b), "downloading")
        XCTAssertEqual(events.map(\.0), ["onError", "onDownloadEnd"]); XCTAssertTrue(engine.deleted.contains(a))
    }
    func testDeduplicationAndProgressBeforeCommit() throws {
        let a = try admit("same"); XCTAssertEqual(a, try admit("same")); XCTAssertEqual(engine.tasks.count, 1)
        engine.latest(a).progress(TransferProgress(fraction: 1, received: 100, total: 100))
        let status = try run("getDownloadStatus", ["id": .string(a)]) as! [String: Any]
        XCTAssertLessThan(status["progress"] as! Double, 1); XCTAssertTrue(events.isEmpty)
        engine.latest(a).progress(TransferProgress(fraction: 0.1, received: 10, total: 100))
        let later = try run("getDownloadStatus", ["id": .string(a)]) as! [String: Any]
        XCTAssertEqual(later["progress"] as! Double, status["progress"] as! Double)
        XCTAssertEqual(store.rows[a]?.progress, status["progress"] as? Double)
        engine.complete(a); _ = try state(a); XCTAssertNotEqual(a, try admit("same"))
    }
    func testPersistenceFailureNeverEmitsSuccess() throws {
        let a = try admit("a"); store.failWrites = true; engine.complete(a)
        XCTAssertThrowsError(try state(a)) { XCTAssertEqual(($0 as? OfflineError)?.code, "E_STORAGE") }
        XCTAssertEqual(events.map(\.0), ["onError"]); XCTAssertEqual(store.rows[a]?.state, .downloading)
    }
    func testRecoveryHonorsCancelPauseAndIOSExpiryMetadata() throws {
        store.rows = [
            "c": DownloadRecord(id: "c", url: "https://media.test/c.mp4", options: [:], fingerprint: "c", order: 1, stopIntent: "cancel"),
            "p": DownloadRecord(id: "p", url: "https://media.test/p.mp4", options: [:], fingerprint: "p", order: 2, state: .paused, stopIntent: "pause"),
            "e": DownloadRecord(id: "e", url: "https://media.test/e.mp4", options: [:], fingerprint: "e", order: 3, state: .completed, asset: OfflineAsset(path: "file:///e.mp4", duration: 1, date: 1), expiresAt: 1),
        ]
        queue = OfflineQueue(store: store, engine: engine) { [weak self] name, payload in self?.events.append((name, payload)) }
        _ = try run("registerPlugin")
        XCTAssertNil(try state("c")); XCTAssertEqual(try state("p"), "paused"); XCTAssertEqual(try state("e"), "completed")
        XCTAssertTrue(engine.tasks.isEmpty); XCTAssertTrue(events.isEmpty)
    }
    func testDeletionIntentSurvivesMediaRemovalBeforeMetadataFailure() throws {
        let id = try admit("remove"); engine.complete(id); _ = try state(id)
        store.failRemoves = true
        XCTAssertThrowsError(try run("deleteDownloadedAsset", ["id": .string(id)]))
        XCTAssertEqual(store.rows[id]?.stopIntent, "delete"); XCTAssertTrue(engine.deleted.contains(id))
        store.failRemoves = false
        queue = OfflineQueue(store: store, engine: engine) { [weak self] name, payload in self?.events.append((name, payload)) }
        _ = try run("registerPlugin")
        XCTAssertNil(try state(id)); XCTAssertNil(store.rows[id])
        XCTAssertEqual(events.filter { $0.0 == "onDownloadEnd" }.count, 1)
    }
    func testCleanupFailureDoesNotRestartFailedDownload() throws {
        let id = try admit("failure"); engine.failDeletes = true
        engine.latest(id).finished(.failed(OfflineError(code: "E_NETWORK", message: "Network failed.")))
        XCTAssertThrowsError(try state(id)); XCTAssertEqual(store.rows[id]?.state, .failed)
        engine.failDeletes = false
        queue = OfflineQueue(store: store, engine: engine) { [weak self] name, payload in self?.events.append((name, payload)) }
        _ = try run("registerPlugin")
        XCTAssertEqual(try state(id), "failed"); XCTAssertEqual(engine.tasks.count, 1)
    }

    func testNativeBackgroundRecoveryRespectsDurableEnablementAndPause() throws {
        store.rows = [
            "p": DownloadRecord(id: "p", url: "https://media.test/p.mp4", options: [:], fingerprint: "p", order: 1),
            "u": DownloadRecord(id: "u", url: "https://media.test/u.mp4", options: [:], fingerprint: "u", order: 2, state: .paused),
        ]
        store.enabledValue = false
        queue = OfflineQueue(store: store, engine: engine) { _, _ in }
        queue.restoreBackground()
        XCTAssertThrowsError(try run("getDownloadsStatus")); XCTAssertTrue(engine.tasks.isEmpty)
        store.enabledValue = true
        queue = OfflineQueue(store: store, engine: engine) { _, _ in }
        queue.restoreBackground()
        XCTAssertEqual(try state("p"), "downloading"); XCTAssertEqual(try state("u"), "paused")
        XCTAssertEqual(engine.tasks.map { $0.record.id }, ["p"])
    }

    func testInitialConfigurationDoesNotEnableWorker() throws {
        _ = try run("disablePlugin")
        queue = OfflineQueue(store: store, engine: engine) { _, _ in }
        try limit(2)
        let config = try run("getConfig") as! [String: Any]
        XCTAssertEqual(config["maxParallelDownloads"] as? Int, 2)
        XCTAssertFalse(store.enabledValue); XCTAssertTrue(engine.tasks.isEmpty)
        XCTAssertThrowsError(try admit("not-registered"))
        _ = try run("registerPlugin")
        XCTAssertEqual((try run("getConfig") as! [String: Any])["maxParallelDownloads"] as? Int, 2)
    }
    func testRetryBackoffIsDurableBoundedAndOnlyExhaustionIsTerminal() throws {
        var clock = 1000.75 // Wall-clock milliseconds need not be an integer.
        queue = OfflineQueue(store: store, engine: engine, now: { clock }) { [weak self] name, payload in self?.events.append((name, payload)) }
        _ = try run("setConfig", ["config": .object(["retry": .object(["maxRetries": .number(2), "initialDelayMS": .number(60000), "maxDelayMS": .number(120000)])])])
        _ = try run("registerPlugin"); let id = try admit("retry")
        engine.latest(id).finished(.failed(OfflineError(code: "E_NETWORK", message: "Temporary failure.", retryable: true)))
        XCTAssertEqual(try state(id), "pending"); XCTAssertEqual(store.rows[id]?.nextRetryAt, 61000)
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(engine.tasks.count, 1)
        clock = 61000; queue.setNetworkState(connected: true, wifi: true)
        XCTAssertEqual(try state(id), "downloading"); XCTAssertEqual(engine.retriesPrepared, 1)
        engine.latest(id).finished(.failed(OfflineError(code: "E_NETWORK", message: "Temporary failure.", retryable: true)))
        XCTAssertEqual(try state(id), "pending"); XCTAssertEqual(store.rows[id]?.nextRetryAt, 181000)
        clock = 181000; queue.setNetworkState(connected: true, wifi: true)
        XCTAssertEqual(try state(id), "downloading")
        engine.latest(id).finished(.failed(OfflineError(code: "E_NETWORK", message: "Temporary failure.", retryable: true)))
        XCTAssertEqual(try state(id), "failed"); XCTAssertEqual(engine.tasks.count, 3)
        XCTAssertEqual(events.map(\.0), ["onError", "onDownloadEnd"])
    }
    func testDenialNeverAutomaticallyRetries() throws {
        _ = try run("setConfig", ["config": .object(["retry": .object(["maxRetries": .number(3)])])])
        let id = try admit("denied")
        engine.latest(id).finished(.failed(OfflineError(code: "E_DRM_LICENSE_DENIED", message: "Denied.", retryable: true)))
        XCTAssertEqual(try state(id), "failed"); XCTAssertEqual(engine.tasks.count, 1)
    }
    func testRetryTimerRunsWithoutProgressListenersOrPolling() throws {
        _ = try run("setConfig", ["config": .object(["retry": .object(["maxRetries": .number(1), "initialDelayMS": .number(100)])])])
        let id = try admit("timer")
        let restarted = expectation(description: "automatic retry started")
        engine.onStart = { restarted.fulfill() }
        engine.latest(id).finished(.failed(OfflineError(code: "E_NETWORK", message: "Temporary failure.", retryable: true)))
        wait(for: [restarted], timeout: 3)
        XCTAssertEqual(try state(id), "downloading")
        XCTAssertEqual(engine.tasks.count, 2); XCTAssertTrue(events.isEmpty)
    }
    func testWifiWaitsAndNetworkRecoveryDoesNotUndoUserPause() throws {
        _ = try run("setConfig", ["config": .object(["wifiOnly": .bool(true)])])
        let id = try admit("wifi")
        XCTAssertTrue(engine.tasks.isEmpty)
        XCTAssertEqual((try run("getDownloadStatus", ["id": .string(id)]) as! [String: Any])["waitingForNetwork"] as? Bool, true)
        queue.setNetworkState(connected: true, wifi: true); XCTAssertEqual(try state(id), "downloading")
        queue.setNetworkState(connected: true, wifi: false); XCTAssertEqual(try state(id), "pending"); XCTAssertTrue(engine.latest(id).stopped)
        engine.latest(id).finished(.stopped); _ = try state(id)
        XCTAssertEqual(engine.tasks.count, 1)
        _ = try run("pauseDownload", ["id": .string(id)])
        queue.setNetworkState(connected: true, wifi: true); XCTAssertEqual(try state(id), "paused")
        _ = try run("resumeDownload", ["id": .string(id)]); XCTAssertEqual(try state(id), "downloading")
    }
    func testConfigurationSurvivesQueueRestart() throws {
        _ = try run("setConfig", ["config": .object(["wifiOnly": .bool(true), "retry": .object(["maxRetries": .number(2)])])])
        queue = OfflineQueue(store: store, engine: engine) { _, _ in }
        let config = try run("getConfig") as! [String: Any]
        XCTAssertEqual(config["wifiOnly"] as? Bool, true)
        XCTAssertEqual((config["retry"] as? [String: Any])?["maxRetries"] as? Int, 2)
    }
    func testRenewalBlocksDeletionAndDisableWaitsForCommit() throws {
        let id = try admit("license"); engine.complete(id); _ = try state(id)
        let renewed = expectation(description: "renewed"), disabled = expectation(description: "disabled")
        var released = false
        queue.execute("renewDRMLicense", ["id": .string(id)]) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }; renewed.fulfill()
        }
        _ = try state(id)
        XCTAssertThrowsError(try run("deleteDownloadedAsset", ["id": .string(id)]))
        _ = try run("expireDownloadedAssetAt", ["id": .string(id), "timestamp": .number(123456)])
        queue.execute("disablePlugin", [:]) { _ in disabled.fulfill() }
        _ = try run("getConfig")
        engine.licenseCompletion?(.success(LicenseUpdate(status: ["id": id, "scheme": "fairplay", "state": "unknown", "checkedAt": 1], release: { released = true })))
        wait(for: [renewed, disabled], timeout: 2)
        XCTAssertTrue(released); XCTAssertEqual(store.rows[id]?.state, .completed)
        XCTAssertEqual(store.rows[id]?.expiresAt, 123456)
    }
    func testTransferRateResetsAndExpiresWhenStalled() {
        var rate = TransferRate()
        rate.record(0, at: 0); rate.record(1000, at: 1000)
        XCTAssertEqual(rate.rate(at: 1000), 1000)
        XCTAssertEqual(rate.rate(at: 5000), 0)
        rate.record(10, at: 5001); XCTAssertNil(rate.rate(at: 5001))
        rate.record(nil, at: 6000); XCTAssertNil(rate.rate(at: 6000))
    }

    func testWifiPolicyAndLimitChangeWaitForEveryOldTransfer() throws {
        queue.setNetworkState(connected: true, wifi: true)
        let first = try admit("first"), second = try admit("second")
        let configured = expectation(description: "policy applied")
        var finished = false
        queue.execute("setConfig", ["config": .object(["wifiOnly": .bool(true), "maxParallelDownloads": .number(1)])]) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            finished = true; configured.fulfill()
        }
        _ = try run("getConfig")
        XCTAssertTrue(engine.latest(first).stopped); XCTAssertTrue(engine.latest(second).stopped)
        engine.latest(first).finished(.stopped); _ = try run("getConfig")
        XCTAssertFalse(finished)
        engine.latest(second).finished(.stopped)
        wait(for: [configured], timeout: 2)
        XCTAssertEqual(try state(first), "downloading"); XCTAssertEqual(try state(second), "pending")
    }

}
