import Foundation
import AVFoundation

/// AVFoundation owns the media package. Only its bookmark/task journal lives in
/// Application Support; a completed package is never moved or rewritten.
final class HLSDownloadEngine: NSObject, AVAssetDownloadDelegate {
    private struct Checkpoint: Codable {
        let id: String
        var taskID: Int
        let duration: Double
        var relativeLocation: String?
        var complete = false
        var removing = false
        var variantSignatures: [String]
        var observedVariants: [String] = []
        var requiresDRM: Bool?
        var keyIdentifiers: [String]?
        var mediaSelections: [String: [Data]]?
        var variantReceiptVersion: Int?
        var wifiOnly: Bool?
    }
    private final class Job: MediaTransfer {
        let record: DownloadRecord
        let task: AVAssetDownloadTask?
        let keys: FairPlaySession?
        let progress: (TransferProgress) -> Void
        private let finished: (TransferResult) -> Void
        private weak var engine: HLSDownloadEngine?
        private let lock = NSLock()
        private var settled = false
        private var stopped = false
        var observation: NSKeyValueObservation?
        private var verification: Task<Void, Never>?
        init(_ record: DownloadRecord, _ task: AVAssetDownloadTask?, _ engine: HLSDownloadEngine,
             keys: FairPlaySession? = nil, _ progress: @escaping (TransferProgress) -> Void, _ finished: @escaping (TransferResult) -> Void) {
            self.record = record; self.task = task; self.engine = engine; self.keys = keys; self.progress = progress; self.finished = finished
        }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() {
            lock.lock(); guard !settled && !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
            engine?.pause(self)
        }
        func finish(_ outcome: TransferResult) {
            lock.lock(); guard !settled else { lock.unlock(); return }; settled = true; lock.unlock()
            observation?.invalidate(); observation = nil; engine?.settled(self); finished(outcome)
        }
        func verify(_ operation: @escaping () async -> Void) {
            lock.lock()
            if stopped || settled { lock.unlock(); finish(.stopped); return }
            verification = Task { await operation() }; lock.unlock()
        }
        func cancelVerification() -> Bool {
            lock.lock(); let task = verification; lock.unlock()
            task?.cancel(); return task != nil
        }
    }
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var tasks: [String: AVAssetDownloadTask] = [:]
    private var jobs: [String: Job] = [:]
    private var keyOwners: [String: FairPlaySession] = [:]
    private var cancellation: [String: DispatchSemaphore] = [:]
    private var restored = false
    private var restorationRemaining = 2
    private let restorationGroup = DispatchGroup()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private lazy var session = makeSession(wifiOnly: false)
    private lazy var wifiSession = makeSession(wifiOnly: true)
    private func downloadSession(_ record: DownloadRecord) -> AVAssetDownloadURLSession { record.options["_wifiOnly"]?.bool == true ? wifiSession : session }
    private func makeSession(wifiOnly: Bool) -> AVAssetDownloadURLSession {
        let identifier = "org.openoffline.hls.\(Bundle.main.bundleIdentifier ?? "application")" + (wifiOnly ? ".wifi" : "")
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false; config.allowsCellularAccess = !wifiOnly
        // Reconcile on ordinary app launch without requiring AppDelegate edits.
        config.sessionSendsLaunchEvents = false
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: delegateQueue)
    }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
        restorationGroup.enter()
        for (wifiOnly, session) in [(false, session), (true, wifiSession)] {
            session.getAllTasks { [weak self] all in
                guard let self else { return }
                self.lock.lock()
                for case let task as AVAssetDownloadTask in all {
                    guard let id = task.taskDescription, UUID(uuidString: id) != nil,
                          let checkpoint = try? self.load(id), (checkpoint.wifiOnly ?? false) == wifiOnly, checkpoint.taskID == task.taskIdentifier else { task.cancel(); continue }
                    // Let the durable FIFO coordinator decide which restored tasks
                    // can resume, including user-paused and disabled downloads.
                    if task.state == .running { task.suspend() }; self.tasks[id] = task
                }
                self.restorationRemaining -= 1
                guard self.restorationRemaining == 0 else { self.lock.unlock(); return }
                self.restored = true; let waiters = self.waiters; self.waiters.removeAll()
                self.lock.unlock(); self.restorationGroup.leave(); waiters.forEach { $0.resume() }
            }
        }
    }
    private func restoration() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if restored { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    private func checkpointURL(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }
    private func load(_ id: String) throws -> Checkpoint? {
        let url = checkpointURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
    }
    private func save(_ checkpoint: Checkpoint) throws { try JSONEncoder().encode(checkpoint).write(to: checkpointURL(checkpoint.id), options: .atomic) }
    private func location(_ checkpoint: Checkpoint) -> URL? {
        guard let relative = checkpoint.relativeLocation else { return nil }
        return ManagedPackageLocation.resolve(relative, under: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }
    func requiredKeyIdentifiers(_ record: DownloadRecord) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let checkpoint = try load(record.id), checkpoint.complete, let identifiers = checkpoint.keyIdentifiers, !identifiers.isEmpty else { throw OfflineError(code: "E_DRM_INIT_DATA", message: "This asset has no saved FairPlay identifiers; download it again before renewal.") }
        return Set(identifiers)
    }
    func owns(_ record: DownloadRecord) -> Bool { FileManager.default.fileExists(atPath: checkpointURL(record.id).path) }
    func playbackURL(_ record: DownloadRecord) -> URL? { lock.lock(); defer { lock.unlock() }; return (try? load(record.id)).flatMap(location) }

    func resume(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) async throws -> MediaTransfer? {
        await restoration(); try Task.checkCancellation()
        if needsPreparationRestart(record) {
            // Cancellation is acknowledged before deleting a package or reusing
            // its journal ID; an old delegate cannot mutate the replacement.
            // An incomplete URL-only receipt cannot be upgraded into proof of
            // codec/bitrate selection. Reprepare it with the current receipt.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do { try self.delete(record); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation(); return nil
        }
        return try resumeRestored(record, progress: progress, finished: finished)
    }
    private func needsPreparationRestart(_ record: DownloadRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let checkpoint = try? load(record.id) else { return false }
        // Preserve previously completed packages rather than invalidating them
        // merely because their older journal did not record these attributes.
        return !checkpoint.complete && (record.options["drm"] != nil || checkpoint.variantReceiptVersion != 2 || (checkpoint.wifiOnly ?? false) != (record.options["_wifiOnly"]?.bool ?? false))
    }
    private func resumeRestored(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer? {
        lock.lock(); defer { lock.unlock() }
        guard let checkpoint = try load(record.id) else { return nil }
        guard !checkpoint.removing else { throw OfflineError(code: "E_INVALID_STATE", message: "This HLS asset is being removed.") }
        if checkpoint.complete {
            let job = Job(record, nil, self, progress, finished); jobs[record.id] = job
            verify(job, checkpoint); return job
        }
        guard let task = tasks[record.id], task.state != .completed, task.state != .canceling else {
            // iOS may discard a transfer after force-quit. Remove only the
            // abandoned package and restart this same logical queue item.
            if let url = location(checkpoint), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.removeItem(at: checkpointURL(record.id)); return nil
        }
        let job = Job(record, task, self, progress, finished); jobs[record.id] = job
        observe(job); task.resume(); return job
    }

    func start(_ record: DownloadRecord, inspection: MediaInspection, keys: FairPlaySession?, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) async throws -> MediaTransfer {
        await restoration(); try Task.checkCancellation()
        let title = record.options["metadata"]?.object?["title"]?.string ?? inspection.asset.url.lastPathComponent
        let plan = try await HLSDownloadPlan.prepare(inspection, options: record.options, title: title, prepareAsset: { keys?.attach($0) })
        if plan.requiresDRM {
            guard let keys, !plan.keyIdentifiers.isEmpty else { throw OfflineError(code: "E_DRM_REQUIRED", message: "The selected encrypted HLS package requires identifiable FairPlay keys.") }
            try await keys.prepare(plan.keyIdentifiers)
            try await keys.assertPersistentRights(required: true)
        }
        if record.options["checkStorageBeforeDownload"]?.bool == true, let expected = plan.estimatedBytes {
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let capacity, capacity - 16 * 1024 * 1024 < expected { throw OfflineError(code: "E_INSUFFICIENT_STORAGE", message: "There is not enough free storage for the selected HLS media.") }
        }
        try Task.checkCancellation()
        let selections = try await selectionReceipt(plan, asset: inspection.asset)
        try Task.checkCancellation()
        return try launch(record, plan: plan, selections: selections, keys: keys, progress: progress, finished: finished)
    }
    private func selectionReceipt(_ plan: HLSDownloadPlan, asset: AVURLAsset) async throws -> [String: [Data]] {
        let configurations = [plan.configuration.primaryContentConfiguration] + plan.configuration.auxiliaryContentConfigurations
        var receipt: [String: [Data]] = [:]
        for (name, characteristic) in [("audio", AVMediaCharacteristic.audible), ("text", AVMediaCharacteristic.legible)] {
            guard let group = try await asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            let options = Set(configurations.flatMap(\.mediaSelections).compactMap { $0.selectedMediaOption(in: group) })
            receipt[name] = try options.map { try PropertyListSerialization.data(fromPropertyList: $0.propertyList(), format: .binary, options: 0) }
        }
        return receipt
    }
    private func launch(_ record: DownloadRecord, plan: HLSDownloadPlan, selections: [String: [Data]], keys: FairPlaySession?, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
        lock.lock(); defer { lock.unlock() }
        let signatures = plan.variants.map(Self.signature)
        guard Set(signatures).count == signatures.count else {
            throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "The selected native HLS variants cannot be distinguished for offline verification.")
        }
        let task = downloadSession(record).makeAssetDownloadTask(downloadConfiguration: plan.configuration)
        task.taskDescription = record.id
        do { try save(Checkpoint(id: record.id, taskID: task.taskIdentifier, duration: plan.duration, variantSignatures: signatures, requiresDRM: plan.requiresDRM, keyIdentifiers: Array(plan.keyIdentifiers), mediaSelections: selections, variantReceiptVersion: 2, wifiOnly: record.options["_wifiOnly"]?.bool ?? false)) }
        catch { task.cancel(); throw OfflineError(code: "E_STORAGE", message: "The HLS transfer journal could not be saved.") }
        let job = Job(record, task, self, keys: keys, progress, finished)
        tasks[record.id] = task; jobs[record.id] = job
        if let keys { keyOwners[record.id] = keys }
        observe(job); task.resume(); return job
    }
    private func observe(_ job: Job) {
        guard let task = job.task else { return }
        job.observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak job] progress, _ in
            guard let job, !job.isStopped else { return }
            let bytes = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive
            job.progress(TransferProgress(fraction: progress.fractionCompleted, received: bytes >= 0 ? bytes : nil, total: total > 0 ? total : nil))
        }
    }
    private func pause(_ job: Job) {
        job.keys?.cancel()
        if job.cancelVerification() { return } // verification reports its own stop acknowledgement
        guard let task = job.task else { job.finish(.stopped); return }
        if task.state == .running { task.suspend() }
        downloadSession(job.record).getAllTasks { _ in
            // The completion queue is a native acknowledgement boundary. Late
            // progress is ignored and any completed package remains journaled.
            if task.state == .suspended || task.state == .completed { job.finish(.stopped) }
            else { task.cancel(); job.finish(.failed(OfflineError(code: "E_NATIVE", message: "The HLS task could not be suspended."))) }
        }
    }
    func delete(_ record: DownloadRecord) throws {
        guard restorationGroup.wait(timeout: .now() + 30) == .success else { throw OfflineError(code: "E_BUSY", message: "HLS background tasks have not been restored yet.", retryable: true) }
        lock.lock()
        let task = tasks[record.id]
        keyOwners[record.id]?.cancel()
        var checkpoint: Checkpoint?
        do { checkpoint = try load(record.id) } catch { lock.unlock(); throw error }
        checkpoint?.removing = true
        do { if let checkpoint { try save(checkpoint) } }
        catch { lock.unlock(); throw error }
        let signal = DispatchSemaphore(value: 0)
        // The task may already report .completed before its delegate has
        // delivered the final package URL. Keep the journal until that callback
        // boundary has drained; checking task.state alone can orphan a package.
        let awaitingCancellation = task != nil
        if awaitingCancellation { cancellation[record.id] = signal; task?.cancel() }
        lock.unlock()
        if awaitingCancellation, signal.wait(timeout: .now() + 30) != .success {
            throw OfflineError(code: "E_BUSY", message: "The HLS task has not acknowledged cancellation yet.", retryable: true)
        }
        lock.lock(); defer { lock.unlock() }
        // A location callback can arrive while cancellation is in flight.
        // Re-read its durable result rather than deleting from the old snapshot.
        let finalCheckpoint = try load(record.id)
        if let finalCheckpoint, let url = location(finalCheckpoint), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let receipt = checkpointURL(record.id)
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        tasks.removeValue(forKey: record.id); jobs.removeValue(forKey: record.id); cancellation.removeValue(forKey: record.id)
        keyOwners.removeValue(forKey: record.id)
    }
    private func settled(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        if jobs[job.record.id] === job { jobs.removeValue(forKey: job.record.id) }
        if job.task == nil || job.task?.state == .completed { keyOwners.removeValue(forKey: job.record.id) }
    }
    func valid(_ record: DownloadRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let checkpoint = try? load(record.id), checkpoint.complete, !checkpoint.removing,
              let url = location(checkpoint), FileManager.default.fileExists(atPath: url.path) else { return false }
        if checkpoint.requiresDRM == true && (try? FairPlayVault.shared.hasKeys(record.id, identifiers: checkpoint.keyIdentifiers ?? [])) != true { return false }
        return AVURLAsset(url: url).assetCache?.isPlayableOffline == true
    }
    private func verify(_ job: Job, _ checkpoint: Checkpoint) {
        job.verify {
            do {
                guard let url = self.location(checkpoint), FileManager.default.fileExists(atPath: url.path) else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The completed HLS package is missing.") }
                let asset = AVURLAsset(url: url)
                let verificationKeys: FairPlaySession?
                if checkpoint.requiresDRM == true {
                    verificationKeys = try FairPlaySession(record: job.record, offlineOnly: true)
                    verificationKeys?.attach(asset)
                    try await verificationKeys?.prepare(Set(checkpoint.keyIdentifiers ?? []))
                    try await verificationKeys?.assertPersistentRights(required: true)
                } else { verificationKeys = nil }
                let duration = try await asset.load(.duration)
                guard asset.assetCache?.isPlayableOffline == true, duration.seconds.isFinite, duration.seconds >= 0 else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "AVFoundation did not confirm an offline-playable HLS package.") }
                try await self.verifySelections(checkpoint, asset: asset)
                withExtendedLifetime(verificationKeys) {}
                try Task.checkCancellation(); guard !job.isStopped else { job.finish(.stopped); return }
                job.finish(.complete(OfflineAsset(path: url.absoluteString, duration: (duration.seconds * 1000).rounded(.down), date: (Date().timeIntervalSince1970 * 1000).rounded(.down)), nil, nil))
            } catch {
                if job.isStopped { job.finish(.stopped) }
                else { job.finish(.failed(error as? OfflineError ?? OfflineError(code: "E_CORRUPT_ASSET", message: "The downloaded HLS package could not be verified."))) }
            }
        }
    }
    private func verifySelections(_ checkpoint: Checkpoint, asset: AVURLAsset) async throws {
        // isPlayableOffline guarantees a complete rendition, not every selected
        // language/subtitle. Persist AVFoundation's own option identity so the
        // cache proof survives process restart without guessing by display name.
        for (name, characteristic) in [("audio", AVMediaCharacteristic.audible), ("text", AVMediaCharacteristic.legible)] {
            guard let expected = checkpoint.mediaSelections?[name], !expected.isEmpty else { continue }
            guard let group = try await asset.loadMediaSelectionGroup(for: characteristic), let cache = asset.assetCache else {
                throw OfflineError(code: "E_CORRUPT_ASSET", message: "A selected HLS media group is missing from the downloaded package.")
            }
            let cached = cache.mediaSelectionOptions(in: group)
            for data in expected {
                let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                guard let option = group.mediaSelectionOption(withPropertyList: propertyList), cached.contains(option) else {
                    throw OfflineError(code: "E_CORRUPT_ASSET", message: "A selected HLS audio or subtitle rendition is not available offline.")
                }
            }
        }
    }
    private func noteLocation(_ task: AVAssetDownloadTask, _ url: URL, session: URLSession) {
        guard let id = task.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            guard var checkpoint = try load(id), checkpoint.taskID == task.taskIdentifier,
                  (checkpoint.wifiOnly ?? false) == (session === wifiSession) else { return }
            checkpoint.relativeLocation = try ManagedPackageLocation.relativePath(of: url,
                under: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            try save(checkpoint)
        } catch {
            tasks[id]?.cancel()
            let failure: OfflineError
            if let known = error as? OfflineError { failure = known }
            else {
                let mapped = OfflineError.media(error)
                if mapped.code == "E_INSUFFICIENT_STORAGE" { failure = mapped }
                else {
                    let native = error as NSError
                    // Include a useful native category/code without exposing
                    // package paths or provider credentials from userInfo.
                    let category = [NSCocoaErrorDomain: "Cocoa", NSPOSIXErrorDomain: "POSIX", NSURLErrorDomain: "URL"][native.domain] ?? "native"
                    failure = OfflineError(code: "E_STORAGE", message: "The HLS package location could not be saved (\(category) error \(native.code)).", retryable: mapped.retryable)
                }
            }
            jobs[id]?.finish(.failed(failure))
        }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) { noteLocation(assetDownloadTask, location, session: session) }
    @available(iOS 18.0, *)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) { noteLocation(assetDownloadTask, location, session: session) }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadVariants variants: [AVAssetVariant]) {
        guard let id = assetDownloadTask.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            guard var checkpoint = try load(id), checkpoint.taskID == assetDownloadTask.taskIdentifier,
                  (checkpoint.wifiOnly ?? false) == (session === wifiSession) else { return }
            guard checkpoint.variantReceiptVersion == 2 else { return } // the queue will reprepare an incomplete legacy task
            let received = Set(variants.map(Self.signature))
            let expected = Set(checkpoint.variantSignatures)
            guard received.isSubset(of: expected) else {
                assetDownloadTask.cancel(); jobs[id]?.finish(.failed(OfflineError(code: "E_INVALID_TRACKS", message: "AVFoundation chose different variants from the requested selection."))); return
            }
            checkpoint.variantSignatures = Array(expected)
            checkpoint.observedVariants = Array(Set(checkpoint.observedVariants).union(received)); try save(checkpoint)
        } catch {
            assetDownloadTask.cancel(); jobs[id]?.finish(.failed(OfflineError(code: "E_STORAGE", message: "The selected HLS variants could not be saved.")))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        if let current = tasks[id], current !== task { return }
        tasks.removeValue(forKey: id)
        if let signal = cancellation.removeValue(forKey: id) { signal.signal(); return }
        do {
            guard var checkpoint = try load(id), checkpoint.taskID == task.taskIdentifier, !checkpoint.removing,
                  (checkpoint.wifiOnly ?? false) == (session === wifiSession) else { return }
            if let error {
                if let job = jobs[id] { job.finish(job.isStopped ? .stopped : .failed(OfflineError.media(error))) }
                return
            }
            guard checkpoint.variantReceiptVersion == 2 else { return }
            guard Set(checkpoint.observedVariants) == Set(checkpoint.variantSignatures) else {
                jobs[id]?.finish(.failed(OfflineError(code: "E_INVALID_TRACKS", message: "AVFoundation did not confirm all requested variants."))); return
            }
            checkpoint.complete = true; try save(checkpoint)
            if let job = jobs[id], !job.isStopped { verify(job, checkpoint) }
        } catch { jobs[id]?.finish(.failed(OfflineError(code: "E_STORAGE", message: "HLS completion could not be saved."))) }
    }
    private static func signature(_ variant: AVAssetVariant) -> String {
        let size = variant.videoAttributes?.presentationSize ?? .zero
        // A master may reuse the same video URI for AAC, AC-3 and E-AC-3
        // variants. The URL alone cannot establish which variant was chosen.
        let videoCodecs = variant.videoAttributes?.codecTypes.map { String(describing: $0) }.sorted().joined(separator: ",") ?? ""
        let audioFormats = variant.audioAttributes?.formatIDs.map { String(describing: $0) }.sorted().joined(separator: ",") ?? ""
        var fields = ["variant-v2", "peak=\(variant.peakBitRate ?? -1)", "average=\(variant.averageBitRate ?? -1)",
            "width=\(size.width)", "height=\(size.height)", "fps=\(variant.videoAttributes?.nominalFrameRate ?? -1)",
            "videoRange=\(variant.videoAttributes.map { String(describing: $0.videoRange) } ?? "")",
            "videoCodecs=" + videoCodecs, "audioFormats=" + audioFormats]
        if #available(iOS 26.0, macOS 26.0, *) { fields.append("url=" + HLSManifest.resourceIdentity(variant.url)) }
        return fields.joined(separator: "\u{1f}")
    }
}
