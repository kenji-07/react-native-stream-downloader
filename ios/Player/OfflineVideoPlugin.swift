import Foundation
import AVFoundation
import ObjectiveC
import react_native_video

/// All player hooks consult this short in-memory boundary, never SQLite.
final class OfflineRoutes {
    struct Route { let record: DownloadRecord; let url: URL }
    final class Lease {
        private let release: () -> Void
        init(_ release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var owned = Set<String>()
    private var aliases: [String: String] = [:]
    private var readers: [String: Int] = [:]
    private var removing = Set<String>()
    private var maintaining = Set<String>()
    func beginMaintenance(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard (readers[id] ?? 0) == 0, !maintaining.contains(id), !removing.contains(id) else { throw OfflineError(code: "E_ASSET_IN_USE", message: "Stop playback before renewing this asset license.", retryable: true) }
        maintaining.insert(id)
    }
    func endMaintenance(_ id: String) { lock.lock(); maintaining.remove(id); lock.unlock() }
    private var enabled = false
    private func identity(_ url: URL) -> String { url.standardizedFileURL.path }
    func setEnabled(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    func remember(_ previous: URL, assetID: String) {
        lock.lock(); defer { lock.unlock() }
        let key = identity(previous); aliases[key] = assetID; owned.insert(key)
    }
    func committed(_ values: [Route]) {
        lock.lock(); defer { lock.unlock() }
        var next: [String: Route] = [:]
        for route in values where !removing.contains(route.record.id) && route.record.stopIntent != "delete" {
            let key = identity(route.url); owned.insert(key); next[key] = route
            // Also intercept a stale container path already handed to JS. The
            // route still resolves to the current native package location.
            if let path = route.record.asset?.path, let old = URL(string: path), old.isFileURL {
                let alias = identity(old); owned.insert(alias); next[alias] = route
            }
            for (alias, id) in aliases where id == route.record.id { next[alias] = route }
        }
        routes = next
    }
    func acquire(_ url: URL) -> (owned: Bool, route: Route?, lease: Lease?) {
        lock.lock(); defer { lock.unlock() }
        let key = identity(url)
        guard owned.contains(key) else { return (false, nil, nil) }
        guard enabled, let route = routes[key], !removing.contains(route.record.id), !maintaining.contains(route.record.id) else { return (true, nil, nil) }
        readers[route.record.id, default: 0] += 1
        let lease = Lease { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            let count = (self.readers[route.record.id] ?? 1) - 1
            if count == 0 { self.readers.removeValue(forKey: route.record.id) } else { self.readers[route.record.id] = count }
        }
        return (true, route, lease)
    }
    func deleting(_ id: String, operation: () throws -> Void) throws {
        lock.lock()
        guard (readers[id] ?? 0) == 0, !maintaining.contains(id) else { lock.unlock(); throw OfflineError(code: "E_ASSET_IN_USE", message: "The offline asset is currently in use by a player.", retryable: true) }
        removing.insert(id); lock.unlock()
        defer { lock.lock(); removing.remove(id); lock.unlock() }
        try operation()
    }
}

/// Associate ownership with the prepared AVAsset rather than a global DRM
/// manager. Releasing the player item releases both the key session and lease.
final class OfflineVideoPlugin: RNVAVPlayerPlugin {
    private final class Owner: NSObject {
        private let lease: OfflineRoutes.Lease
        private let keys: FairPlaySession?
        init(_ lease: OfflineRoutes.Lease, _ keys: FairPlaySession?) { self.lease = lease; self.keys = keys }
        deinit { keys?.cancel() }
    }
    private static var ownerKey: UInt8 = 0
    private let routes: OfflineRoutes
    init(routes: OfflineRoutes) { self.routes = routes; super.init() }
    override func overridePlayerAsset(source: VideoSource, asset: AVAsset) async -> OverridePlayerAssetResult? {
        guard let original = asset as? AVURLAsset, original.url.isFileURL else { return nil }
        let match = routes.acquire(original.url)
        guard match.owned else { return nil }
        guard let route = match.route, let lease = match.lease else { return unavailable() }
        do {
            let prepared = AVURLAsset(url: route.url, options: [AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetAllowsExpensiveNetworkAccessKey: false, AVURLAssetAllowsConstrainedNetworkAccessKey: false])
            let keys: FairPlaySession?
            if route.record.options["drm"] != nil {
                keys = try FairPlaySession(record: route.record, offlineOnly: true); keys?.attach(prepared)
            } else { keys = nil }
            // A managed HLS package must be wholly cached. A missing cache entry
            // becomes an invalid local asset, never an original network URL.
            if route.url.pathExtension == "movpkg", prepared.assetCache?.isPlayableOffline != true { return unavailable() }
            objc_setAssociatedObject(prepared, &Self.ownerKey, Owner(lease, keys), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return OverridePlayerAssetResult(type: .full, asset: prepared)
        } catch { return unavailable() }
    }
    private func unavailable() -> OverridePlayerAssetResult {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stream-downloader-unavailable-" + UUID().uuidString)
        return OverridePlayerAssetResult(type: .full, asset: AVURLAsset(url: url))
    }
}
