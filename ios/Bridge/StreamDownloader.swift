import Foundation
import React

@objc(StreamDownloader)
final class StreamDownloader: RCTEventEmitter {
    private let work = DispatchQueue(label: "org.openoffline.bridge")
    private let lock = NSLock()
    private var runtime: NativeRuntime?
    private var runtimeID: String?
    private var sequence: Int64 = 0
    private var progress = false
    private var observing = false
    private var invalidated = false
    override static func requiresMainQueueSetup() -> Bool { false }
    override func supportedEvents() -> [String]! { ["StreamDownloaderEvent", "StreamDownloaderLicenseRequest"] }
    override func startObserving() { lock.lock(); observing = true; lock.unlock() }
    override func stopObserving() { lock.lock(); observing = false; lock.unlock() }

    @objc(execute:resolver:rejecter:)
    func execute(_ command: [String: Any], resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        work.async {
            var method = "execute"
            do {
                self.lock.lock(); let invalidated = self.invalidated; self.lock.unlock()
                guard !invalidated else { throw OfflineError(code: "E_RUNTIME_INVALIDATED", message: "The JavaScript runtime is no longer active.") }
                let input = try Validation.object(JSONValue(command))
                guard try Validation.integer(input["version"]) == 1 else { throw OfflineError(code: "E_BRIDGE", message: "Unsupported native bridge version.") }
                let incoming = try Validation.string(input["runtimeId"])
                _ = try Validation.string(input["operationId"])
                method = try Validation.string(input["method"])
                let params = try Validation.params(method, Validation.object(input["params"]))
                let runtime = try NativeRuntime.get()
                self.lock.lock()
                self.runtime = runtime
                if method == "registerPlugin" {
                    if self.runtimeID != incoming { self.runtimeID = incoming; self.sequence = 0 }
                    runtime.attach(self); runtime.queue.setProgressEnabled(self.progress)
                }
                let matching = self.runtimeID == incoming
                self.lock.unlock()
                if method == "registerPlugin" {
                    FairPlayLicenseBroker.shared.attach(runtimeID: incoming) { [weak self] in self?.emitLicense($0) ?? false }
                }
                guard matching || ["disablePlugin", "getConfig", "setConfig"].contains(method) else { throw OfflineError(code: "E_NOT_REGISTERED", message: "The JavaScript runtime is not registered.") }
                if method == "getAvailableTracks" {
                    runtime.queue.execute("getConfig", [:]) { result in
                        switch result {
                        case let .failure(error): self.reject(error, "getAvailableTracks", reject)
                        case let .success(configuration):
                            let wifiOnly = (configuration as? [String: Any])?["wifiOnly"] as? Bool ?? false
                            Task {
                                do {
                                    guard let value = params["url"]?.string, let url = URL(string: value) else { throw OfflineError.invalid("Invalid media URL.") }
                                    let headers = NativeMediaCatalog.headers(params)
                                    resolve(try await NativeMediaCatalog.inspect(url, wifiOnly: wifiOnly, headers: headers).publicTracks)
                                } catch { self.reject(error as? OfflineError ?? OfflineError(code: "E_MEDIA_INSPECTION", message: "Native media track inspection failed."), "getAvailableTracks", reject) }
                            }
                        }
                    }
                    return
                }
                let operation = method
                runtime.queue.execute(method, params) { result in
                    switch result {
                    case let .success(value): resolve(value)
                    case let .failure(error): self.reject(error, operation, reject)
                    }
                }
            } catch { self.reject(error, method, reject) }
        }
    }

    @objc(setProgressEnabled:enabled:)
    func setProgressEnabled(_ incoming: String, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard runtimeID == nil || runtimeID == incoming else { return }
        progress = enabled; runtime?.queue.setProgressEnabled(enabled)
    }
    @objc(completeLicenseRequest:resolver:rejecter:)
    func completeLicenseRequest(_ response: [String: Any], resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        lock.lock(); let current = invalidated ? nil : runtimeID; lock.unlock()
        do { try FairPlayLicenseBroker.shared.complete(response, runtimeID: current); resolve(nil) }
        catch { self.reject(error, "completeLicenseRequest", reject) }
    }
    func emit(_ event: String, _ payload: Any) {
        lock.lock()
        guard let runtimeID, !invalidated, observing else { lock.unlock(); return }
        sequence += 1
        let envelope: [String: Any] = ["runtimeId": runtimeID, "sequence": sequence, "event": event, "payload": payload]
        // Native queue serializes event creation; sendEvent enqueues onto RN.
        sendEvent(withName: "StreamDownloaderEvent", body: envelope)
        lock.unlock()
    }
    func emitLicense(_ request: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, observing, let runtimeID, request["runtimeId"] as? String == runtimeID else { return false }
        sequence += 1
        var envelope = request; envelope["sequence"] = sequence
        sendEvent(withName: "StreamDownloaderLicenseRequest", body: envelope)
        return true
    }
    private func reject(_ error: Error, _ operation: String, _ reject: RCTPromiseRejectBlock) {
        let value = error as? OfflineError ?? OfflineError(code: "E_NATIVE", message: "Native download operation failed.")
        reject(value.code, value.message, NSError(domain: "StreamDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: value.message, "operation": operation, "retryable": value.retryable]))
    }
    override func invalidate() {
        lock.lock(); invalidated = true; let runtime = self.runtime; let current = runtimeID; lock.unlock()
        FairPlayLicenseBroker.shared.detach(runtimeID: current)
        runtime?.detach(self); runtime?.queue.setProgressEnabled(false)
        super.invalidate()
    }
}
