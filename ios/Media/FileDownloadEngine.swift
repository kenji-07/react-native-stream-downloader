import Foundation
import AVFoundation

/// Background progressive transfers with a separate durable selection journal.
/// System tasks are reconciled before the coordinator admits replacement work.
final class FileDownloadEngine: NSObject, MediaEngine, URLSessionDownloadDelegate {
    private struct Plan: Codable {
        let fingerprint: String
        let selected: [CMPersistentTrackID]?
        let trackTypes: [String: String]
        var taskID: Int?
        var exported: Bool?
        var removing: Bool?
        var errorCode: String?
        var errorMessage: String?
        var errorRetryable: Bool?
        var fileName: String?
        var verifiedBytes: Int64?
        var wifiOnly: Bool?
    }
    private final class Job: MediaTransfer {
        let record: DownloadRecord
        let progress: (TransferProgress) -> Void
        let finished: (TransferResult) -> Void
        let resumeURL: URL
        let plan: Plan
        private weak var engine: FileDownloadEngine?
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var verification: Task<Void, Never>?
        private var verifying = false
        private var stopped = false
        private var settled = false
        private var cancelAcknowledged = false
        private var taskAcknowledged = false
        private var pendingError: OfflineError?
        var usedResumeData = false // confined to the engine lock/delegate queue
        init(_ record: DownloadRecord, _ resumeURL: URL, _ plan: Plan, _ engine: FileDownloadEngine,
             _ progress: @escaping (TransferProgress) -> Void, _ finished: @escaping (TransferResult) -> Void) {
            self.record = record; self.resumeURL = resumeURL; self.plan = plan; self.engine = engine
            self.progress = progress; self.finished = finished
        }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        var abortError: OfflineError? { lock.lock(); defer { lock.unlock() }; return pendingError }
        func bind(_ task: URLSessionDownloadTask) {
            lock.lock(); self.task = task; taskAcknowledged = false; cancelAcknowledged = false
            let cancel = stopped || settled; lock.unlock()
            if cancel { task.cancel() } else { task.resume() }
        }
        func abort(_ error: OfflineError) {
            lock.lock(); pendingError = error; let task = self.task; lock.unlock(); task?.cancel()
        }
        func stop() {
            lock.lock(); if stopped || settled { lock.unlock(); return }; stopped = true
            if verifying { let operation = verification; lock.unlock(); operation?.cancel(); return }
            let task = self.task; lock.unlock()
            guard let task else { finish(.stopped); return }
            task.cancel { data in
                do { if let data { try data.write(to: self.resumeURL, options: .atomic) } }
                catch { self.lock.lock(); self.pendingError = OfflineError(code: "E_STORAGE", message: "Download resume data could not be saved."); self.lock.unlock() }
                self.lock.lock(); self.cancelAcknowledged = true; let done = self.taskAcknowledged; let error = self.pendingError; self.lock.unlock()
                if done { self.finish(error.map(TransferResult.failed) ?? .stopped) }
            }
        }
        func acknowledgeTaskCancellation() {
            lock.lock(); taskAcknowledged = true; let done = stopped && cancelAcknowledged; let error = pendingError; lock.unlock()
            if done { finish(error.map(TransferResult.failed) ?? .stopped) }
        }
        func finish(_ result: TransferResult) {
            lock.lock(); if settled { lock.unlock(); return }; settled = true; lock.unlock()
            engine?.settled(self); finished(result)
        }
        func verify(_ operation: @escaping () async throws -> TransferResult) {
            lock.lock()
            if stopped || settled || verifying { lock.unlock(); return }
            verifying = true
            verification = Task {
                let outcome: TransferResult
                do { outcome = try await operation() }
                catch { outcome = .failed(OfflineError.media(error)) }
                self.verificationFinished(outcome)
            }
            lock.unlock()
        }
        private func verificationFinished(_ outcome: TransferResult) {
            lock.lock(); verifying = false; let stopped = self.stopped; lock.unlock()
            finish(stopped ? .stopped : outcome)
        }
    }
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var jobs: [String: Job] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var cancellations: [String: DispatchSemaphore] = [:]
    private let restoration = DispatchGroup()
    private lazy var session = makeSession(wifiOnly: false)
    private lazy var wifiSession = makeSession(wifiOnly: true)
    private func downloadSession(_ record: DownloadRecord) -> URLSession { record.options["_wifiOnly"]?.bool == true ? wifiSession : session }
    private func makeSession(wifiOnly: Bool) -> URLSession {
        let identifier = "org.openoffline.mp4.\(Bundle.main.bundleIdentifier ?? "application")" + (wifiOnly ? ".wifi" : "")
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false; config.allowsCellularAccess = !wifiOnly
        // No AppDelegate swizzle/host edits: reconcile on ordinary app launch.
        config.sessionSendsLaunchEvents = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
        for session in [session, wifiSession] {
            restoration.enter()
            session.getAllTasks { [weak self] all in
                guard let self else { return }
                self.lock.lock()
                for case let task as URLSessionDownloadTask in all {
                    guard let id = task.taskDescription, UUID(uuidString: id) != nil,
                          let plan = try? self.load(id), plan.taskID == task.taskIdentifier, (plan.wifiOnly ?? false) == (session === self.wifiSession), plan.removing != true else {
                        task.cancel(); continue
                    }
                    if task.state == .running { task.suspend() }
                    self.tasks[id] = task
                }
                self.lock.unlock(); self.restoration.leave()
            }
        }
    }
    private func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func load(_ id: String) throws -> Plan? {
        let path = folder(id).appendingPathComponent("plan.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Plan.self, from: Data(contentsOf: path))
    }
    private func save(_ id: String, _ plan: Plan) throws {
        try JSONEncoder().encode(plan).write(to: folder(id).appendingPathComponent("plan.json"), options: .atomic)
    }
    private func waitForRestoration() throws {
        guard restoration.wait(timeout: .now() + 30) == .success else {
            throw OfflineError(code: "E_BUSY", message: "MP4 background tasks have not been restored yet.", retryable: true)
        }
    }
    func start(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
        try start(record, plan: Plan(fingerprint: record.fingerprint, selected: nil, trackTypes: [:]), progress: progress, finished: finished)
    }
    func startPrepared(_ record: DownloadRecord, selected: Set<CMPersistentTrackID>?, trackTypes: [String: String], progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
        try start(record, plan: Plan(fingerprint: record.fingerprint, selected: selected.map { Array($0).sorted() }, trackTypes: trackTypes,
            fileName: MediaFilename.mp4(title: record.options["metadata"]?.object?["title"]?.string, selected: selected != nil)), progress: progress, finished: finished)
    }
    func resume(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer? {
        try waitForRestoration()
        lock.lock(); let restoredPlan: Plan?
        do { restoredPlan = try load(record.id); lock.unlock() } catch { lock.unlock(); throw error }
        guard var plan = restoredPlan else { return nil }
        if (plan.wifiOnly ?? false) != (record.options["_wifiOnly"]?.bool ?? false), plan.verifiedBytes == nil {
            try delete(record); plan.taskID = nil; plan.exported = nil
        }
        guard plan.fingerprint == record.fingerprint else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The MP4 transfer plan does not match this download.") }
        return try start(record, plan: plan, progress: progress, finished: finished)
    }
    private func start(_ record: DownloadRecord, plan: Plan, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
        var plan = plan; plan.wifiOnly = record.options["_wifiOnly"]?.bool ?? false
        guard record.options["drm"] == nil else { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "FairPlay offline downloads require an HLS stream.") }
        guard let url = URL(string: record.url) else { throw OfflineError(code: "E_INVALID_URL", message: "Invalid media URL.") }
        try waitForRestoration()
        lock.lock(); defer { lock.unlock() }
        guard plan.removing != true else { throw OfflineError(code: "E_INVALID_STATE", message: "This MP4 asset is being removed.") }
        if let code = plan.errorCode { throw OfflineError(code: code, message: plan.errorMessage ?? "The background MP4 download failed.", retryable: plan.errorRetryable ?? false) }
        let location = folder(record.id)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        try save(record.id, plan)
        let resumeURL = location.appendingPathComponent("resume.data")
        let job = Job(record, resumeURL, plan, self, progress, finished)
        jobs[record.id] = job
        if FileManager.default.fileExists(atPath: location.appendingPathComponent("video.mp4").path) ||
            (plan.selected == nil || plan.exported == true) && FileManager.default.fileExists(atPath: finalURL(record.id, plan).path) {
            verify(job); return job
        }
        if let existing = tasks[record.id], existing.state != .completed && existing.state != .canceling {
            job.bind(existing); return job
        }
        let task: URLSessionDownloadTask
        if FileManager.default.fileExists(atPath: resumeURL.path) {
            task = downloadSession(record).downloadTask(withResumeData: try Data(contentsOf: resumeURL)); job.usedResumeData = true
        } else { task = downloadSession(record).downloadTask(with: url) }
        try launch(task, job: job); return job
    }
    private func launch(_ task: URLSessionDownloadTask, job: Job) throws {
        task.taskDescription = job.record.id
        do {
            var plan = try load(job.record.id) ?? job.plan
            plan.taskID = task.taskIdentifier; try save(job.record.id, plan)
        } catch { task.cancel(); jobs.removeValue(forKey: job.record.id); throw error }
        tasks[job.record.id] = task; job.bind(task)
    }
    private func settled(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        if jobs[job.record.id] === job { jobs.removeValue(forKey: job.record.id) }
    }
    func prepareRetry(_ record: DownloadRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard var plan = try load(record.id), plan.errorRetryable == true else { return }
        plan.errorCode = nil; plan.errorMessage = nil; plan.errorRetryable = nil
        try save(record.id, plan)
    }
    func delete(_ record: DownloadRecord) throws {
        try waitForRestoration()
        lock.lock()
        let task = tasks[record.id]
        do { if var plan = try load(record.id) { plan.removing = true; try save(record.id, plan) } }
        catch { lock.unlock(); throw error }
        let signal = DispatchSemaphore(value: 0)
        if let task, task.state != .completed { cancellations[record.id] = signal; task.cancel() }
        lock.unlock()
        if let task, task.state != .completed, signal.wait(timeout: .now() + 30) != .success {
            throw OfflineError(code: "E_BUSY", message: "The MP4 task has not acknowledged cancellation yet.", retryable: true)
        }
        lock.lock(); defer { lock.unlock() }
        let path = folder(record.id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        tasks.removeValue(forKey: record.id); jobs.removeValue(forKey: record.id); cancellations.removeValue(forKey: record.id)
    }
    /// Recreate paths under the current sandbox after an app-container relocation.
    func playbackURL(_ record: DownloadRecord) -> URL? {
        guard record.asset != nil else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let plan = try? load(record.id), plan.removing != true else { return nil }
        return finalURL(record.id, plan)
    }
    private func finalURL(_ id: String, _ plan: Plan) -> URL {
        folder(id).appendingPathComponent(plan.fileName ?? (plan.selected == nil ? "video.mp4" : "selected.mp4"))
    }
    func valid(_ record: DownloadRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let url = playbackURL(record), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, let plan = try? load(record.id) else { return false }
        return size.int64Value > 0 && (plan.verifiedBytes == nil || plan.verifiedBytes == size.int64Value)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let job = downloadTask.taskDescription.flatMap { id in
            tasks[id] === downloadTask ? jobs[id] : nil
        }
        lock.unlock()
        guard let job, !job.isStopped else { return }
        let total = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        if job.record.options["checkStorageBeforeDownload"]?.bool == true, let total, total > totalBytesWritten {
            do {
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let capacity, capacity - 16 * 1024 * 1024 < total - totalBytesWritten {
                    job.abort(OfflineError(code: "E_INSUFFICIENT_STORAGE", message: "There is not enough free storage for this download.")); return
                }
            } catch { job.abort(OfflineError(code: "E_STORAGE", message: "Available storage could not be checked.")); return }
        }
        job.progress(TransferProgress(fraction: total.map { $0 > 0 ? Double(totalBytesWritten) / Double($0) : 0 } ?? 0, received: totalBytesWritten, total: total))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            guard let plan = try load(id), plan.taskID == downloadTask.taskIdentifier, (plan.wifiOnly ?? false) == (session === wifiSession), plan.removing != true else { return }
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw OfflineError(code: "E_NETWORK", message: "The media server returned an unsuccessful response.", retryable: code == 408 || code == 429 || (500...599).contains(code))
            }
            let destination = folder(id).appendingPathComponent("video.mp4")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            // The rename completes before the system may discard its temporary URL,
            // including when no JavaScript runtime or admitted Job exists yet.
            try FileManager.default.moveItem(at: location, to: destination)
            if let job = jobs[id], !job.isStopped { verify(job) }
        } catch { noteFailure(id, OfflineError.media(error)) }
    }
    private func markExported(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var plan = try load(id), plan.removing != true else { throw OfflineError(code: "E_INVALID_STATE", message: "MP4 export was removed during verification.") }
        plan.exported = true; try save(id, plan)
    }
    private func markVerified(_ id: String, size: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard var plan = try load(id), plan.removing != true else { throw OfflineError(code: "E_INVALID_STATE", message: "The MP4 transfer journal is unavailable.") }
        plan.verifiedBytes = size; try save(id, plan)
    }
    private func verify(_ job: Job) {
        job.verify {
            let source = self.folder(job.record.id).appendingPathComponent("video.mp4")
            let exported = self.finalURL(job.record.id, job.plan)
            let staging = self.folder(job.record.id).appendingPathComponent("export.pending.mp4")
            var destination = FileManager.default.fileExists(atPath: source.path) ? source : exported
            if let selected = job.plan.selected {
                if job.plan.exported != true || !FileManager.default.fileExists(atPath: exported.path) {
                    if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                    _ = try await MP4Exporter.export(sourceURL: source, selectedTrackIDs: Set(selected), destinationURL: staging)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: exported.path) { try FileManager.default.removeItem(at: exported) }
                    try FileManager.default.moveItem(at: staging, to: exported)
                    try self.markExported(job.record.id)
                }
                destination = exported
            }
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let protected = try await asset.load(.hasProtectedContent)
            guard !tracks.isEmpty, duration.seconds.isFinite, duration.seconds >= 0 else { throw OfflineError(code: "E_INVALID_STREAM", message: "The MP4 does not contain valid playable media.") }
            guard !protected else { throw OfflineError(code: "E_DRM_REQUIRED", message: "Encrypted MP4 offline export is not supported.") }
            if !job.plan.trackTypes.isEmpty {
                let expected = job.plan.selected.map { ids in ids.compactMap { job.plan.trackTypes[String($0)] } } ?? Array(job.plan.trackTypes.values)
                let actual = tracks.compactMap { Self.trackType($0.mediaType) }
                guard actual.sorted() == expected.sorted() else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The completed MP4 does not contain exactly the requested tracks.") }
            }
            try Task.checkCancellation()
            if job.plan.selected == nil && destination != exported {
                if FileManager.default.fileExists(atPath: exported.path) { try FileManager.default.removeItem(at: exported) }
                try FileManager.default.moveItem(at: destination, to: exported); destination = exported
            }
            if FileManager.default.fileExists(atPath: job.resumeURL.path) { try FileManager.default.removeItem(at: job.resumeURL) }
            if job.plan.selected != nil && FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
            guard let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value, size > 0 else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The verified MP4 file is empty.") }
            try self.markVerified(job.record.id, size: size)
            return .complete(OfflineAsset(path: destination.absoluteString, duration: (duration.seconds * 1000).rounded(.down), date: (Date().timeIntervalSince1970 * 1000).rounded(.down)), size, size)
        }
    }
    private static func trackType(_ type: AVMediaType) -> String? {
        switch type { case .audio: return "audio"; case .video: return "video"; case .text, .subtitle, .closedCaption: return "text"; default: return nil }
    }
    private func noteFailure(_ id: String, _ error: OfflineError) {
        do {
            if var plan = try load(id) {
                plan.errorCode = error.code; plan.errorMessage = error.message; plan.errorRetryable = error.retryable
                try save(id, plan)
            }
            jobs[id]?.finish(.failed(error))
        } catch { jobs[id]?.finish(.failed(OfflineError(code: "E_STORAGE", message: "The MP4 failure could not be saved."))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        lock.lock(); defer { lock.unlock() }
        let owned = tasks[id] === task
        if owned {
            tasks.removeValue(forKey: id)
            if let signal = cancellations.removeValue(forKey: id) { signal.signal(); return }
        }
        do {
            guard let plan = try load(id), plan.taskID == task.taskIdentifier, (plan.wifiOnly ?? false) == (session === wifiSession) else {
                if owned { jobs[id]?.finish(.failed(OfflineError(code: "E_CORRUPT_ASSET", message: "The MP4 task journal is missing or no longer matches."))) }
                return
            }
        } catch { jobs[id]?.finish(.failed(OfflineError(code: "E_STORAGE", message: "The MP4 task journal could not be read."))); return }
        let job = jobs[id]
        job?.acknowledgeTaskCancellation()
        if job?.isStopped == true { return }
        guard let error else { return }
        // A failed opaque resume is restarted once as a fresh native request;
        // bytes from different validators/responses are never appended by us.
        if let job, job.usedResumeData, job.abortError == nil, (error as NSError).domain == NSURLErrorDomain,
           (error as NSError).code != NSURLErrorCancelled, let url = URL(string: job.record.url) {
            job.usedResumeData = false
            do {
                if FileManager.default.fileExists(atPath: job.resumeURL.path) { try FileManager.default.removeItem(at: job.resumeURL) }
                try launch(session.downloadTask(with: url), job: job); return
            } catch { noteFailure(id, OfflineError.media(error)); return }
        }
        // A cancelled restored task with no Job belongs to user pause or native
        // removal; its durable intent is reconciled by OfflineQueue.
        if job == nil && (error as NSError).code == NSURLErrorCancelled { return }
        noteFailure(id, job?.abortError ?? OfflineError.media(error))
    }
}
