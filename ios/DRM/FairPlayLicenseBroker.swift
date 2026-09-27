import Foundation

/// The private bridge owns bounded, once-only request correlation. Callback
/// references never survive runtime teardown or enter the durable asset store.
final class FairPlayLicenseBroker: @unchecked Sendable {
    static let shared = FairPlayLicenseBroker()
    private struct Pending: Sendable {
        let runtimeID: String
        let assetID: String
        let generation: Int64
        let continuation: CheckedContinuation<Data, Error>
    }
    // Sendability is provided by this lock, not by queue affinity: every access
    // to runtimeID, emitter and pending is synchronized. Continuations are
    // removed under the lock and resumed after unlocking, so timeout, response,
    // cancellation and teardown can race without settling a request twice.
    // The sole emitter boundary is StreamDownloader.emitLicense, which guards
    // its own runtime/event state with its lock and supports concurrent calls.
    private let lock = NSLock()
    private var runtimeID: String?
    private var emitter: (([String: Any]) -> Bool)?
    private var pending: [String: Pending] = [:]
    func attach(runtimeID: String, emitter: @escaping ([String: Any]) -> Bool) {
        lock.lock()
        let obsolete = self.runtimeID == runtimeID ? [] : Array(pending.values)
        if self.runtimeID != runtimeID { pending.removeAll() }
        self.runtimeID = runtimeID; self.emitter = emitter; lock.unlock()
        obsolete.forEach { $0.continuation.resume(throwing: unavailable()) }
    }
    func detach(runtimeID: String?) {
        lock.lock()
        guard self.runtimeID == runtimeID else { lock.unlock(); return }
        self.runtimeID = nil; emitter = nil; let requests = Array(pending.values); pending.removeAll(); lock.unlock()
        requests.forEach { $0.continuation.resume(throwing: unavailable()) }
    }
    func request(callbackRef: String, assetID: String, generation: Int64, spc: Data,
                 contentID: String, licenseURL: String, identifier: String) async throws -> Data {
        let requestID = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard let runtimeID, let emitter, callbackRef.hasPrefix(runtimeID + ":"), !Task.isCancelled else {
                    lock.unlock(); continuation.resume(throwing: unavailable()); return
                }
                pending[requestID] = Pending(runtimeID: runtimeID, assetID: assetID, generation: generation, continuation: continuation)
                lock.unlock()
                let envelope: [String: Any] = ["runtimeId": runtimeID, "requestId": requestID, "callbackRef": callbackRef,
                    "assetId": assetID, "generation": generation, "spcString": spc.base64EncodedString(),
                    "contentId": contentID, "licenseUrl": licenseURL, "loadedLicenseUrl": identifier]
                if !emitter(envelope) { finish(requestID, .failure(unavailable())) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                    self?.finish(requestID, .failure(OfflineError(code: "E_DRM_TIMEOUT", message: "The application DRM callback timed out.")))
                }
            }
        }, onCancel: { self.finish(requestID, .failure(CancellationError())) })
    }
    func complete(_ response: [String: Any], runtimeID: String?) throws {
        guard let incoming = response["runtimeId"] as? String, let id = response["requestId"] as? String,
              incoming == runtimeID else { return } // stale runtimes cannot settle current requests
        lock.lock(); let request = pending[id]; lock.unlock()
        guard request?.runtimeID == incoming else { return }
        let result: Result<Data, Error>
        if let error = response["error"] as? [String: Any] {
            let incomingCode = error["code"] as? String ?? ""
            let code = ["E_DRM_TIMEOUT", "E_DRM_CALLBACK_UNAVAILABLE"].contains(incomingCode) ? incomingCode : "E_DRM_LICENSE"
            result = .failure(OfflineError(code: code, message: "The application DRM callback failed."))
        } else if let encoded = response["ckcBase64"] as? String, !encoded.isEmpty, encoded.utf8.count <= 16 * 1024 * 1024,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.base64EncodedString() == encoded {
            result = .success(data)
        } else { result = .failure(OfflineError(code: "E_DRM_LICENSE", message: "The DRM callback must return canonical Base64 CKC data.")) }
        finish(id, result)
    }
    func cancel(assetID: String, generation: Int64) {
        lock.lock()
        let ids = pending.filter { $0.value.assetID == assetID && $0.value.generation == generation }.map(\.key)
        let requests = ids.compactMap { pending.removeValue(forKey: $0) }; lock.unlock()
        requests.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }
    private func finish(_ id: String, _ result: Result<Data, Error>) {
        lock.lock(); let request = pending.removeValue(forKey: id); lock.unlock()
        request?.continuation.resume(with: result)
    }
    private func unavailable() -> OfflineError { OfflineError(code: "E_DRM_CALLBACK_UNAVAILABLE", message: "The original JavaScript DRM callback is unavailable; enqueue the download again with a live callback.") }
}
