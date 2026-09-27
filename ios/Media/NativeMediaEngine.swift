import Foundation
import AVFoundation

/// Preparation consumes the same logical queue slot as transfer and verification.
final class NativeMediaEngine: MediaEngine {
    private let policyLock = NSLock()
    private var wifiOnly = false
    private var networkWifiOnly: Bool { policyLock.lock(); defer { policyLock.unlock() }; return wifiOnly }
    func setWifiOnly(_ value: Bool) { policyLock.lock(); wifiOnly = value; policyLock.unlock() }
    private final class PreparingTransfer: MediaTransfer {
        private let lock = NSLock()
        private var preparation: Task<Void, Never>?
        private var child: MediaTransfer?
        private var stopped = false
        private var settled = false
        private let finished: (TransferResult) -> Void
        init(_ finished: @escaping (TransferResult) -> Void) { self.finished = finished }
        func bind(_ task: Task<Void, Never>) {
            lock.lock(); if !settled { preparation = task }; let stop = stopped; lock.unlock()
            if stop { task.cancel() }
        }
        func bind(_ transfer: MediaTransfer) {
            lock.lock(); if !settled { child = transfer }; let stop = stopped; lock.unlock()
            if stop { transfer.stop() }
        }
        func stop() {
            lock.lock(); guard !stopped && !settled else { lock.unlock(); return }; stopped = true
            let child = self.child, preparation = self.preparation; lock.unlock()
            if let child { child.stop() } else { preparation?.cancel() }
        }
        func finish(_ result: TransferResult) {
            lock.lock(); guard !settled else { lock.unlock(); return }; settled = true
            preparation = nil; child = nil; let stop = stopped; lock.unlock()
            if case .failed = result { finished(result) }
            else { finished(stop ? .stopped : result) }
        }
    }
    let routes = OfflineRoutes()
    private let files: FileDownloadEngine
    private let hls: HLSDownloadEngine
    init(directory: URL) throws {
        files = try FileDownloadEngine(directory: directory)
        hls = try HLSDownloadEngine(directory: directory.appendingPathComponent("hls-journal", isDirectory: true))
    }
    func start(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer {
        var configured = record; configured.options["_wifiOnly"] = .bool(networkWifiOnly)
        let record = configured
        let transfer = PreparingTransfer(finished)
        let task = Task {
            do {
                if let existing = try files.resume(record, progress: progress, finished: transfer.finish) { transfer.bind(existing); return }
                if let existing = try await hls.resume(record, progress: progress, finished: transfer.finish) { transfer.bind(existing); return }
                guard let url = URL(string: record.url) else { throw OfflineError(code: "E_INVALID_URL", message: "Invalid media URL.") }
                let keys = record.options["drm"] == nil ? nil : try FairPlaySession(record: record, offlineOnly: false)
                let inspection: MediaInspection
                do {
                    inspection = try await NativeMediaCatalog.inspect(url, wifiOnly: record.options["_wifiOnly"]?.bool ?? false, prepareAsset: { keys?.attach($0) })
                    try Task.checkCancellation()
                } catch { keys?.cancel(); throw error }
                if inspection.kind == "hls" {
                    do { transfer.bind(try await hls.start(record, inspection: inspection, keys: keys, progress: progress, finished: transfer.finish)) }
                    catch { keys?.cancel(); throw error }
                } else {
                    guard record.options["drm"] == nil else { keys?.cancel(); throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "Persistent FairPlay downloads require an HLS package.") }
                    var selectedRows = inspection.rows
                    for (type, value) in record.options["tracks"]?.object ?? [:] {
                        guard case let .array(ids) = value else { throw OfflineError.invalid("Track IDs must be arrays.") }
                        let actual = Set(inspection.rows.filter { $0["type"] as? String == type }.compactMap { $0["id"] as? String })
                        let selected = Set(ids.compactMap(\.string))
                        guard selected.isSubset(of: actual) else { throw OfflineError(code: "E_INVALID_TRACKS", message: "A selected track is unknown or belongs to changed media.") }
                        selectedRows.removeAll { $0["type"] as? String == type && !selected.contains($0["id"] as? String ?? "") }
                    }
                    guard !selectedRows.isEmpty else { throw OfflineError(code: "E_INVALID_TRACKS", message: "At least one MP4 track must be selected.") }
                    func nativeID(_ row: [String: Any]) throws -> CMPersistentTrackID {
                        guard let id = row["id"] as? String, let component = id.split(separator: ":").last, let number = CMPersistentTrackID(component) else { throw OfflineError(code: "E_MEDIA_INSPECTION", message: "A native MP4 track identifier is invalid.") }
                        return number
                    }
                    let selectedIDs = try Set(selectedRows.map(nativeID))
                    let trackTypes = try Dictionary(uniqueKeysWithValues: inspection.rows.map { (String(try nativeID($0)), $0["type"] as? String ?? "") })
                    try Task.checkCancellation()
                    transfer.bind(try files.startPrepared(record, selected: selectedRows.count == inspection.rows.count ? nil : selectedIDs, trackTypes: trackTypes, progress: progress, finished: transfer.finish))
                }
            } catch {
                transfer.finish(.failed(OfflineError.media(error)))
            }
        }
        transfer.bind(task); return transfer
    }
    func prepareRetry(_ record: DownloadRecord) throws { try files.prepareRetry(record) }
    func license(_ record: DownloadRecord, renew: Bool, config: [String: JSONValue]?, completion: @escaping (Result<LicenseUpdate, Error>) -> Void) {
        guard record.options["drm"] != nil else {
            completion(renew ? .failure(OfflineError(code: "E_DRM_REQUIRED", message: "This asset has no persistent DRM license.")) : .success(LicenseUpdate(status: nil)))
            return
        }
        Task {
            var held = false
            do {
                if renew {
                    try routes.beginMaintenance(record.id); held = true
                    var current = record
                    if let config { current.options["drm"] = .object(config) }
                    current.options["_wifiOnly"] = .bool(networkWifiOnly)
                    let keys = try FairPlaySession(record: current, offlineOnly: false, renewing: true)
                    defer { keys.cancel() }
                    let identifiers = try hls.requiredKeyIdentifiers(record)
                    try await keys.prepare(identifiers)
                    try await keys.commitRenewal(identifiers)
                    // Renewed rights are committed even when the provider cannot report expiry.
                    let status = (try? await FairPlaySession.licenseStatus(record.id)) ?? ["id": record.id, "scheme": "fairplay", "state": "unknown", "checkedAt": (Date().timeIntervalSince1970 * 1000).rounded(.down)]
                    completion(.success(LicenseUpdate(status: status, release: { self.routes.endMaintenance(record.id) })))
                    held = false
                } else { completion(.success(LicenseUpdate(status: try await FairPlaySession.licenseStatus(record.id)))) }
            } catch { if held { routes.endMaintenance(record.id) }; completion(.failure(error)) }
        }
    }
    func delete(_ record: DownloadRecord) throws { try delete(record, beforeRemoving: {}) }
    func delete(_ record: DownloadRecord, beforeRemoving: () throws -> Void) throws {
        try routes.deleting(record.id) {
            try beforeRemoving()
            if hls.owns(record) { try hls.delete(record) }
            try files.delete(record)
            if record.options["drm"] != nil { try FairPlayVault.shared.remove(record.id) }
        }
    }
    func valid(_ record: DownloadRecord) -> Bool { hls.owns(record) ? hls.valid(record) : files.valid(record) }
    func resolvedAsset(_ record: DownloadRecord) -> OfflineAsset? {
        guard let asset = record.asset, let url = hls.owns(record) ? hls.playbackURL(record) : files.playbackURL(record) else { return nil }
        if asset.path != url.absoluteString, let previous = URL(string: asset.path), previous.isFileURL {
            routes.remember(previous, assetID: record.id)
        }
        return OfflineAsset(path: url.absoluteString, duration: asset.duration, date: asset.date)
    }
    func committed(_ records: [DownloadRecord]) {
        routes.committed(records.compactMap { record in
            guard record.state == .completed, let asset = resolvedAsset(record), let url = URL(string: asset.path) else { return nil }
            return OfflineRoutes.Route(record: record, url: url)
        })
    }
    func setPlaybackEnabled(_ enabled: Bool) { routes.setEnabled(enabled) }
}
