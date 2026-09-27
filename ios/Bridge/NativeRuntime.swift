import Foundation
import Network
import react_native_video

final class NativeRuntime {
    private static let initializationLock = NSLock()
    private static var instance: NativeRuntime?
    static func get() throws -> NativeRuntime {
        initializationLock.lock(); defer { initializationLock.unlock() }
        if let instance { return instance }
        let runtime = try NativeRuntime(); instance = runtime; return runtime
    }
    private let observerLock = NSLock()
    private weak var observer: StreamDownloader?
    private(set) var queue: OfflineQueue!
    private let network = NWPathMonitor()
    private var playerPlugin: OfflineVideoPlugin?
    private init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("org.openoffline.streamdownloader", isDirectory: true)
        let store = try SQLiteStore(directory: base)
        let engine = try NativeMediaEngine(directory: base.appendingPathComponent("media", isDirectory: true))
        let plugin = OfflineVideoPlugin(routes: engine.routes); playerPlugin = plugin
        if Thread.isMainThread { ReactNativeVideoManager.shared.registerPlugin(plugin: plugin) }
        else { DispatchQueue.main.sync { ReactNativeVideoManager.shared.registerPlugin(plugin: plugin) } }
        queue = OfflineQueue(store: store, engine: engine) { [weak self] name, payload in
            guard let self else { return }
            self.observerLock.lock(); let observer = self.observer; self.observerLock.unlock()
            observer?.emit(name, payload)
        }
        queue.setNetworkState(connected: false, wifi: false)
        network.pathUpdateHandler = { [weak self] path in
            self?.queue.setNetworkState(connected: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.cellular))
        }
        network.start(queue: DispatchQueue(label: "org.openoffline.network"))
        queue.restoreBackground()
    }
    func attach(_ module: StreamDownloader) { observerLock.lock(); observer = module; observerLock.unlock() }
    func detach(_ module: StreamDownloader) {
        observerLock.lock(); if observer === module { observer = nil }; observerLock.unlock()
    }
}
