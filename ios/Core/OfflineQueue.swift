import Foundation

final class OfflineQueue {
    typealias Completion = (Result<Any?, Error>) -> Void
    private enum Stop: String { case pause, limit, network, disable, cancel }
    private struct Running { let token: Int64; let transfer: MediaTransfer; var stop: Stop?; var rate = TransferRate() }
    private struct Barrier { let ready: () -> Bool; let completion: Completion; let value: Any? }
    private let actor = DispatchQueue(label: "org.openoffline.coordinator")
    private let store: RecordStore
    private let engine: MediaEngine
    private let event: (String, Any) -> Void
    private var records: [String: DownloadRecord] = [:]
    private var active: [String: Running] = [:]
    private var dirtyProgress = Set<String>()
    private var barriers: [Barrier] = []
    private var loaded = false
    private var configurationLoaded = false
    private var policy = DownloadPolicy()
    private var connected = true
    private var wifi = false
    private var networkAllowed: Bool { connected && (!policy.wifiOnly || wifi) }
    private var retryTimer: DispatchSourceTimer?
    private var licensing = Set<String>()
    private let now: () -> Double
    private let monotonic: () -> Double
    private var enabled = false
    private var maxParallel = 5
    private var frequency = 1000
    private var order: Int64 = 0
    private var token: Int64 = 0
    private var progressEnabled = false
    private var timer: DispatchSourceTimer?
    private var fault: OfflineError?

    init(store: RecordStore, engine: MediaEngine, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }, monotonic: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, event: @escaping (String, Any) -> Void) {
        self.store = store; self.engine = engine; self.now = now; self.monotonic = monotonic; self.event = event
    }

    func execute(_ method: String, _ params: [String: JSONValue], completion: @escaping Completion) {
        actor.async {
            do {
                if let fault = self.fault { throw fault }; try self.loadConfiguration()
                switch method {
                case "registerPlugin":
                    try self.recover(); try self.store.setEnabled(true); self.enabled = true; self.engine.setPlaybackEnabled(true)
                    for var record in self.records.values.filter({ $0.disableHeld }) {
                        record.disableHeld = false; record.state = .pending; try self.save(record)
                    }
                    try self.pump(); completion(.success(true))
                case "disablePlugin":
                    try self.recover(); try self.store.setEnabled(false); self.enabled = false; self.engine.setPlaybackEnabled(false)
                    for var record in self.records.values.filter({ $0.state == .pending }) {
                        record.disableHeld = true; record.state = .paused; try self.save(record)
                    }
                    for id in Array(self.active.keys) { try self.stop(id, .disable) }
                    self.barrier({ self.active.isEmpty && self.licensing.isEmpty }, value: true, completion)
                default:
                    guard self.enabled || method == "getConfig" || method == "setConfig" else { throw OfflineError(code: "E_NOT_REGISTERED", message: "Call registerPlugin before using the downloader.") }
                    try self.command(method, params, completion)
                }
                self.checkBarriers(); self.rescheduleIfNeeded()
            } catch { completion(.failure(error)) }
        }
    }

    private func command(_ method: String, _ params: [String: JSONValue], _ completion: @escaping Completion) throws {
        let id = params["id"]?.string ?? ""
        switch method {
        case "getConfig": completion(.success(configuration))
        case "setConfig":
            let config = params["config"]?.object ?? [:]
            let nextPolicy = try policy.updated(config)
            let policyChanged = nextPolicy.wifiOnly != policy.wifiOnly
            let policyTransfers = policyChanged ? active.mapValues(\.token) : [:]
            let limit = Int(config["maxParallelDownloads"]?.number ?? Double(maxParallel))
            let nextFrequency = Int(config["updateFrequencyMS"]?.number ?? Double(frequency))
            let stored = nextPolicy.wire.merging(["maxParallelDownloads": limit, "updateFrequencyMS": nextFrequency]) { _, new in new }
            try store.setConfiguration(try JSONValue(stored).object!)
            frequency = nextFrequency; maxParallel = limit; policy = nextPolicy; engine.setWifiOnly(policy.wifiOnly)
            if policyChanged || !networkAllowed { for id in Array(active.keys) { try stop(id, .network) } }
            let surplus = active.keys.sorted { (records[$0]?.order ?? 0) < (records[$1]?.order ?? 0) }.dropFirst(limit)
            for id in surplus { try stop(id, .limit) }
            reschedule(); try pump(); barrier({
                self.active.count <= limit && !self.active.values.contains(where: { $0.stop == .network }) &&
                    policyTransfers.allSatisfy { self.active[$0.key]?.token != $0.value }
            }, value: nil, completion)
        case "downloadStream":
            let fingerprint = params["fingerprint"]!.string!
            let options = params["options"]!.object!
            var record = records.values.first { $0.state.unfinished && $0.fingerprint == fingerprint }
            if record == nil {
                order += 1
                record = DownloadRecord(id: UUID().uuidString.lowercased(), url: params["url"]!.string!, options: options, fingerprint: fingerprint, order: order, expiresAt: options["expiresAt"]?.number ?? 0)
                try save(record!)
            }
            try persistProgress(record!.id)
            completion(.success(status(record!)))
            do { try pump() } catch { halt(error) }
        case "getDownloadsStatus": try persistProgress(); completion(.success(ordered.map(status)))
        case "getDownloadStatus":
            try persistProgress(id)
            completion(.success(records[id].map(status)))
        case "pauseDownload":
            var record = try requireRecord(id)
            guard record.state.unfinished else { throw OfflineError(code: "E_INVALID_STATE", message: "Only unfinished downloads can be paused.") }
            if active[id] != nil { try stop(id, .pause) }
            else { record.state = .paused; record.disableHeld = false; try save(record) }
            barrier({ self.active[id] == nil }, value: nil, completion)
        case "resumeDownload":
            var record = try requireRecord(id)
            guard record.state.unfinished else { throw OfflineError(code: "E_INVALID_STATE", message: "Only unfinished downloads can be resumed.") }
            guard active[id]?.stop == nil else { throw OfflineError(code: "E_BUSY", message: "Wait for the pending pause or cancellation.", retryable: true) }
            if record.state == .paused { record.state = .pending; record.disableHeld = false; try save(record) }
            try pump(); completion(.success(nil))
        case "cancelDownload", "cancelAllDownloads":
            let ids = method == "cancelDownload" ? [id] : ordered.filter { $0.state.unfinished }.map(\.id)
            for id in ids { try cancel(id) }
            barrier({ ids.allSatisfy { self.active[$0] == nil } }, value: nil, completion)
        case "deleteQueuedItem", "deleteAllQueuedItems":
            let items = method == "deleteQueuedItem" ? records[id].map { [$0] } ?? [] : ordered.filter { [.pending, .paused, .failed].contains($0.state) }
            guard items.allSatisfy({ active[$0.id] == nil && $0.state != .completed }) else { throw OfflineError(code: "E_INVALID_STATE", message: "The queued item is active or completed.") }
            for item in items { try remove(item, emitEnd: item.state.unfinished) }; completion(.success(nil))
        case "getDownloadedAssets":
            let items = ordered.filter { $0.state == .completed }.sorted { ($0.asset?.date ?? 0, $0.id) < ($1.asset?.date ?? 0, $1.id) }
            completion(.success(try items.map { try checkedAsset($0) }))
        case "getDownloadedAsset": completion(.success(try records[id].flatMap { $0.state == .completed ? try checkedAsset($0) : nil }))
        case "deleteDownloadedAsset", "deleteAllDownloadedAssets":
            let items = method == "deleteDownloadedAsset" ? records[id].map { $0.state == .completed ? [$0] : [] } ?? [] : ordered.filter { $0.state == .completed }
            for item in items { try remove(item, emitEnd: false) }; completion(.success(nil))
        case "getDRMLicenseStatus", "renewDRMLicense":
            guard let record = records[id], record.state == .completed else {
                if method == "getDRMLicenseStatus" { completion(.success(nil)); return }
                throw OfflineError(code: "E_ASSET_NOT_FOUND", message: "A completed asset was not found.")
            }
            try license(record, renew: method == "renewDRMLicense", config: params["drm"]?.object, completion: completion)
        case "expireDownloadedAssetAt":
            var record = try requireRecord(id)
            guard record.state == .completed else { throw OfflineError(code: "E_ASSET_NOT_FOUND", message: "A completed asset was not found.") }
            record.expiresAt = params["timestamp"]!.number!; try save(record); completion(.success(nil))
        default: throw OfflineError(code: "E_BRIDGE", message: "Unknown native operation.")
        }
    }

    func setNetworkState(connected: Bool, wifi: Bool) { actor.async {
        do {
            self.connected = connected; self.wifi = wifi
            if !self.networkAllowed { for id in Array(self.active.keys) { try self.stop(id, .network) } }
            try self.pump(); self.rescheduleIfNeeded()
        } catch { self.halt(error) }
    } }
    func setProgressEnabled(_ value: Bool) { actor.async { self.progressEnabled = value; self.reschedule() } }
    /// Native background recovery does not register a JavaScript runtime or
    /// override a durable explicit disable/user pause.
    func restoreBackground() {
        actor.async {
            do {
                guard !self.loaded else { return }
                try self.loadConfiguration(); try self.recover(); self.enabled = try self.store.enabled()
                self.engine.setPlaybackEnabled(self.enabled)
                try self.pump(); self.rescheduleIfNeeded()
            } catch { self.halt(error) }
        }
    }
    private var ordered: [DownloadRecord] { records.values.sorted { $0.order < $1.order } }
    private func recover() throws {
        guard !loaded else { return }
        for var record in try store.load() {
            order = max(order, record.order)
            if record.state == .removed { continue }
            if record.stopIntent == Stop.cancel.rawValue || record.stopIntent == "delete" { try engine.delete(record); try store.remove(record.id); continue }
            if record.state == .failed { try engine.delete(record) }
            if record.stopIntent == Stop.pause.rawValue || record.stopIntent == Stop.disable.rawValue { record.state = .paused }
            else if record.state == .downloading { record.state = .pending }
            if record.state == .completed, let asset = engine.resolvedAsset(record) { record.asset = asset }
            record.stopIntent = nil; try save(record)
            // iOS expiresAt is metadata-only per documented platform behavior.
        }
        loaded = true
        engine.committed(ordered)
    }
    private func save(_ record: DownloadRecord, refreshPlayback: Bool = true) throws {
        do {
            try store.put(record); records[record.id] = record; dirtyProgress.remove(record.id)
            if refreshPlayback { engine.committed(ordered) }
        }
        catch { halt(error); throw fault! }
    }
    private func requireRecord(_ id: String) throws -> DownloadRecord {
        guard let record = records[id] else { throw OfflineError(code: "E_ASSET_NOT_FOUND", message: "The requested download was not found.") }; return record
    }
    private func checkedAsset(_ record: DownloadRecord) throws -> [String: Any] {
        guard engine.valid(record), let asset = engine.resolvedAsset(record) else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "Downloaded media is missing or corrupted.") }
        var current = record
        if asset.path != record.asset?.path { current.asset = asset; try save(current) }
        guard let value = current.downloadedAsset else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "Asset metadata is incomplete.") }
        return value
    }
    private func pump() throws {
        guard enabled && fault == nil && networkAllowed else { return }
        for var record in ordered.filter({ $0.state == .pending && active[$0.id] == nil && ($0.nextRetryAt ?? 0) <= now() }) {
            if active.count >= maxParallel { break }
            record.state = .downloading; record.nextRetryAt = nil; record.error = nil; try save(record)
            token += 1; let current = token; let id = record.id
            do {
                if (record.retryCount ?? 0) > 0 { try engine.prepareRetry(record) }
                let transfer = try engine.start(record, progress: { progress in
                    self.actor.async {
                        guard self.active[id]?.token == current, var item = self.records[id] else { return }
                        self.active[id]?.rate.record(progress.received, at: self.monotonic())
                        let fraction = max(item.progress, progress.fraction.isFinite ? min(0.999999, max(0, progress.fraction)) : 0)
                        if item.progress != fraction || item.received != progress.received || item.total != progress.total {
                            item.progress = fraction; item.received = progress.received; item.total = progress.total
                            self.records[id] = item; self.dirtyProgress.insert(id)
                        }
                    }
                }, finished: { outcome in self.actor.async { self.finish(id, current, outcome) } })
                var running = Running(token: current, transfer: transfer); running.rate.record(record.received, at: monotonic()); active[id] = running
            } catch {
                try failed(record, failure(error))
            }
        }
    }
    private func stop(_ id: String, _ reason: Stop) throws {
        guard var running = active[id], var record = records[id], running.stop != .cancel else { return }
        if running.stop == .pause && reason != .cancel { return }
        if running.stop == .disable && (reason == .limit || reason == .network) { return }
        running.stop = reason; active[id] = running
        record.stopIntent = reason.rawValue; record.disableHeld = reason == .disable
        record.state = reason == .pause || reason == .disable ? .paused : .pending
        try save(record); running.transfer.stop()
    }
    private func cancel(_ id: String) throws {
        guard let record = records[id], record.state.unfinished else { return }
        if active[id] != nil { try stop(id, .cancel) } else { try remove(record, emitEnd: true) }
    }
    private func remove(_ item: DownloadRecord, emitEnd: Bool) throws {
        guard !licensing.contains(item.id) else { throw OfflineError(code: "E_BUSY", message: "Wait for the license operation to finish.", retryable: true) }
        var record = item
        try engine.delete(item) { record.stopIntent = "delete"; try save(record) }
        do { try store.remove(item.id) } catch { halt(error); throw fault! }
        record.state = .removed; record.asset = nil; record.error = nil; record.stopIntent = nil; records[item.id] = record
        engine.committed(ordered)
        if emitEnd { event("onDownloadEnd", status(record)) }
    }
    private func finish(_ id: String, _ token: Int64, _ outcome: TransferResult) {
        guard let running = active[id], running.token == token, var record = records[id] else { return }
        active.removeValue(forKey: id); record.stopIntent = nil
        do {
            if running.stop != nil && running.stop != .cancel, case let .failed(error) = outcome, !(running.stop == .network && error.retryable) { throw error }
            switch running.stop {
            case .cancel: try remove(record, emitEnd: true)
            case .pause: record.state = .paused; try save(record)
            case .disable: record.state = enabled && !record.disableHeld ? .pending : .paused; try save(record)
            case .limit, .network: record.state = .pending; try save(record)
            case nil:
                switch outcome {
                case let .complete(asset, received, total):
                    record.asset = asset; record.received = received; record.total = total; record.progress = 1; record.state = .completed
                    try save(record); event("onDownloadEnd", status(record))
                case let .failed(error):
                    try failed(record, error)
                case .stopped: throw OfflineError(code: "E_ENGINE", message: "Transfer stopped without a queue request.")
                }
            }
            checkBarriers(); try pump(); rescheduleIfNeeded()
        } catch { halt(error) }
    }
    private var configuration: [String: Any] { policy.wire.merging(["maxParallelDownloads": maxParallel, "updateFrequencyMS": frequency]) { _, new in new } }
    private func loadConfiguration() throws {
        guard !configurationLoaded else { return }
        let config = try store.configuration(); policy = try policy.updated(config)
        maxParallel = Int(config["maxParallelDownloads"]?.number ?? Double(maxParallel))
        frequency = Int(config["updateFrequencyMS"]?.number ?? Double(frequency))
        engine.setWifiOnly(policy.wifiOnly); configurationLoaded = true
    }
    private func status(_ record: DownloadRecord) -> [String: Any] {
        var result = record.status
        if record.state == .pending && !networkAllowed { result["waitingForNetwork"] = true }
        if record.state == .downloading, let running = active[record.id], running.stop == nil, let rate = running.rate.rate(at: monotonic()) {
            result["bytesPerSecond"] = rate
            if rate > 0, let total = record.total, let received = record.received { result["estimatedRemainingSeconds"] = Double(max(0, total - received)) / rate }
        }
        return result
    }
    private func failed(_ item: DownloadRecord, _ error: OfflineError) throws {
        var record = item
        let transient = error.retryable && ["E_NETWORK", "E_DRM_LICENSE_REQUEST", "E_DRM_PROVISIONING"].contains(error.code)
        if transient && (record.retryCount ?? 0) < policy.maxRetries {
            record.retryCount = (record.retryCount ?? 0) + 1; record.nextRetryAt = now().rounded(.down) + policy.retryDelay(record.retryCount!)
            record.state = .pending; record.error = error.message; try save(record)
        } else {
            record.state = .failed; record.nextRetryAt = nil; record.error = error.message; try save(record)
            try engine.delete(record); event("onError", error.message); event("onDownloadEnd", status(record))
        }
    }
    private func scheduleRetry() {
        retryTimer?.cancel(); retryTimer = nil
        guard enabled && fault == nil && networkAllowed && active.count < maxParallel,
              let due = records.values.filter({ $0.state == .pending && active[$0.id] == nil }).compactMap(\.nextRetryAt).min() else { return }
        let timer = DispatchSource.makeTimerSource(queue: actor)
        timer.schedule(deadline: .now() + max(0.001, (due - now()) / 1000))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.pump(); self.rescheduleIfNeeded() } catch { self.halt(error) }
        }
        retryTimer = timer; timer.resume()
    }
    private func license(_ record: DownloadRecord, renew: Bool, config: [String: JSONValue]?, completion: @escaping Completion) throws {
        guard !renew || networkAllowed else { throw OfflineError(code: "E_NETWORK_POLICY", message: "Connect to an allowed network before renewing rights.", retryable: true) }
        guard licensing.insert(record.id).inserted else { throw OfflineError(code: "E_BUSY", message: "A license operation is already running for this asset.", retryable: true) }
        engine.license(record, renew: renew, config: config) { result in self.actor.async {
            defer { self.licensing.remove(record.id); self.checkBarriers() }
            do {
                let update = try result.get(); defer { update.release() }
                if renew {
                    // Metadata may have changed while the license request was in flight.
                    var current = try self.requireRecord(record.id)
                    if let asset = update.asset { current.asset = asset }
                    if let config { current.options["drm"] = .object(config) }
                    try self.save(current)
                }
                completion(.success(update.status))
            } catch { completion(.failure(error)) }
        } }
    }

    private func barrier(_ ready: @escaping () -> Bool, value: Any?, _ completion: @escaping Completion) {
        if ready() { completion(.success(value)) } else { barriers.append(Barrier(ready: ready, completion: completion, value: value)) }
    }
    private func checkBarriers() {
        let completed = barriers.filter { $0.ready() }; barriers.removeAll { $0.ready() }
        completed.forEach { $0.completion(.success($0.value)) }
    }
    private func rescheduleIfNeeded() {
        scheduleRetry()
        let needed = progressEnabled && records.values.contains { $0.state.unfinished }
        if needed && timer == nil { reschedule() }
        else if !needed { timer?.cancel(); timer = nil }
    }
    private func reschedule() {
        timer?.cancel(); timer = nil
        guard progressEnabled && records.values.contains(where: { $0.state.unfinished }) else { return }
        let source = DispatchSource.makeTimerSource(queue: actor)
        source.schedule(deadline: .now() + .milliseconds(frequency), repeating: .milliseconds(frequency))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.persistProgress(); self.event("onDownloadProgress", self.ordered.map(self.status)) }
            catch { self.halt(error) }
        }
        timer = source; source.resume()
    }
    private func failure(_ error: Error) -> OfflineError { error as? OfflineError ?? OfflineError(code: "E_STORAGE", message: "Native storage or transfer operation failed.") }
    private func persistProgress(_ id: String) throws {
        guard dirtyProgress.contains(id), active[id] != nil, let record = records[id] else { return }
        // Active-transfer counters do not change completed playback routes.
        try save(record, refreshPlayback: false)
    }
    private func persistProgress() throws {
        // Save before publishing so a process restart cannot regress a progress
        // value that has already been observed by JavaScript.
        for id in Array(dirtyProgress) { try persistProgress(id) }
    }
    private func halt(_ error: Error) {
        guard fault == nil else { return }; fault = failure(error); enabled = false; engine.setPlaybackEnabled(false)
        timer?.cancel(); timer = nil; retryTimer?.cancel(); retryTimer = nil
        active.values.forEach { $0.transfer.stop() }
        let pending = barriers; barriers.removeAll(); pending.forEach { $0.completion(.failure(fault!)) }
        event("onError", fault!.message)
    }
}
