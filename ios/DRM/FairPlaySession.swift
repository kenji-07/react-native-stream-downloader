import Foundation
import AVFoundation

/// An owner is retained by one download job or one player asset. Playback mode
/// answers exclusively from platform-issued persistent blobs, with no transport.
final class FairPlaySession: NSObject, AVContentKeySessionDelegate {
    private let assetID: String
    private let generation: Int64
    private let configuration: [String: JSONValue]
    private let offlineOnly: Bool
    private let renewing: Bool
    private let wifiOnly: Bool
    private var renewedKeys: [String: Data] = [:]
    private let work = DispatchQueue(label: "org.openoffline.fairplay.session")
    private let workKey = DispatchSpecificKey<Bool>()
    private let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private var tasks: [String: Task<Void, Never>] = [:]
    private var recipients: [String: [AVPersistableContentKeyRequest]] = [:]
    private var requested = Set<String>()
    private var accepted = Set<String>()
    private var failure: OfflineError?
    private var cancelled = false
    private let onFailure: ((OfflineError) -> Void)?
    init(record: DownloadRecord, offlineOnly: Bool, renewing: Bool = false, onFailure: ((OfflineError) -> Void)? = nil) throws {
        self.assetID = record.id; generation = record.generation
        configuration = record.options["drm"]?.object ?? [:]
        self.offlineOnly = offlineOnly; self.renewing = renewing; self.wifiOnly = record.options["_wifiOnly"]?.bool ?? false; self.onFailure = onFailure
        super.init(); work.setSpecific(key: workKey, value: true); keySession.setDelegate(self, queue: work)
    }
    /// Must be called before this AVURLAsset starts loading any property.
    func attach(_ asset: AVURLAsset) { keySession.addContentKeyRecipient(asset) }
    func prepare(_ identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            work.async {
                for identifier in identifiers where !self.requested.contains(identifier) && !self.accepted.contains(identifier) {
                    self.keySession.processContentKeyRequest(withIdentifier: identifier, initializationData: nil, options: nil)
                }
                continuation.resume()
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while true {
            try Task.checkCancellation()
            let ready: Bool = try await withCheckedThrowingContinuation { continuation in
                work.async {
                    if let error = self.failure { continuation.resume(throwing: error) }
                    else if self.cancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: identifiers.isSubset(of: self.accepted)) }
                }
            }
            if ready { return }
            guard Date() < deadline else { cancel(); throw OfflineError(code: "E_DRM_TIMEOUT", message: "Persistent FairPlay preparation timed out.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func commitRenewal(_ identifiers: Set<String>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            work.async {
                do {
                    if let error = self.failure { throw error }
                    guard self.renewing, !self.cancelled, self.tasks.isEmpty, identifiers.isSubset(of: self.accepted), identifiers.isSubset(of: Set(self.renewedKeys.keys)) else { throw OfflineError(code: "E_DRM_LICENSE", message: "Renewal is not complete.") }
                    try FairPlayVault.shared.replaceKeys(self.renewedKeys, assetID: self.assetID, configuration: self.configuration)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    // The continuation is consumed once under the lock, including timeout races.
    private final class ExpirationReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Data, Error>) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(with: result)
        }
    }
    static func licenseStatus(_ assetID: String) async throws -> [String: Any] {
        let keys = try FairPlayVault.shared.storedKeys(assetID)
        var status: [String: Any] = ["id": assetID, "scheme": "fairplay", "state": keys.isEmpty ? "missing" : "unknown", "checkedAt": (Date().timeIntervalSince1970 * 1000).rounded(.down)]
        guard !keys.isEmpty else { return status }
        let session = AVContentKeySession(keySystem: .fairPlayStreaming); defer { session.expire() }
        var tokens: [String] = []
        for key in keys {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let reply = ExpirationReply(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { reply.finish(.failure(OfflineError(code: "E_DRM_TIMEOUT", message: "The expiration token request timed out."))) }
                session.makeSecureTokenForExpirationDate(ofPersistableContentKey: key) { token, error in
                    if let token, !token.isEmpty { reply.finish(.success(token)) }
                    else { reply.finish(.failure(OfflineError(code: "E_DRM_STATUS", message: "FairPlay could not create the expiration token."))) }
                }
            }
            tokens.append(data.base64EncodedString())
        }
        status["expirationTokens"] = tokens; return status
    }
    func cancel() {
        FairPlayLicenseBroker.shared.cancel(assetID: assetID, generation: generation)
        let cancel = {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll()
            let error = self.native(OfflineError(code: "E_CANCELLED", message: "The content key request was cancelled."))
            self.recipients.values.flatMap { $0 }.forEach { $0.processContentKeyResponseError(error) }
            self.recipients.removeAll()
        }
        // Deletion may remove rights immediately after this returns. No pending
        // delegate or acquisition result can write the key back after removal.
        if DispatchQueue.getSpecific(key: workKey) == true { cancel() }
        else { work.sync(execute: cancel) }
    }
    func assertPersistentRights(required: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            work.async {
                do {
                    if let failure = self.failure { throw failure }
                    guard !self.cancelled else { throw CancellationError() }
                    guard self.tasks.isEmpty, !required || !self.requested.isEmpty,
                          self.requested.isSubset(of: self.accepted) else {
                        throw OfflineError(code: "E_DRM_LICENSE", message: "AVFoundation has not confirmed every required persistent content key.")
                    }
                    for identifier in self.requested {
                        guard try FairPlayVault.shared.key(self.assetID, identifier: identifier) != nil else {
                            throw OfflineError(code: "E_DRM_LICENSE", message: "A required persistent content key is missing.")
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        do {
            guard !cancelled else { throw CancellationError() }
            _ = try identifier(keyRequest.identifier)
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch { reject(keyRequest, error) }
    }
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        // An offline asset never silently renews via an online streaming license.
        if renewing {
            do { try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError() } catch { reject(keyRequest, error) }
        } else { reject(keyRequest, OfflineError(code: "E_DRM_EXPIRED", message: "The provider requires new rights; call renewDRMLicense while online.")) }
    }
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        do {
            guard !cancelled else { throw CancellationError() }
            let identifier = try identifier(keyRequest.identifier); requested.insert(identifier)
            if !renewing, let persistent = try FairPlayVault.shared.key(assetID, identifier: identifier) {
                keyRequest.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistent)); return
            }
            guard !offlineOnly else { throw OfflineError(code: "E_DRM_LICENSE", message: "The offline content key is missing.") }
            if configuration["requiresCallback"]?.bool == true && configuration["callbackRef"] == nil {
                throw OfflineError(code: "E_DRM_CALLBACK_UNAVAILABLE", message: "The original DRM callback is unavailable; enqueue this download again.")
            }
            recipients[identifier, default: []].append(keyRequest)
            guard tasks[identifier] == nil else { return }
            tasks[identifier] = Task { [weak self] in
                guard let self else { return }
                do {
                    let persistent = try await self.acquire(keyRequest, identifier: identifier)
                    try Task.checkCancellation()
                    self.work.async { self.deliver(identifier, result: .success(persistent)) }
                } catch { self.work.async { self.deliver(identifier, result: .failure(error)) } }
            }
        } catch { reject(keyRequest, error) }
    }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        guard !cancelled else { return }
        if let value = try? identifier(keyRequest.identifier) { accepted.insert(value) }
    }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError error: Error) {
        fail(OfflineError(code: "E_DRM_LICENSE", message: "AVFoundation rejected the offline content rights."))
    }
    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: AVContentKeyRequest.RetryReason) -> Bool { false }
    func contentKeySession(_ session: AVContentKeySession, didUpdatePersistableContentKey persistableContentKey: Data, forContentKeyIdentifier keyIdentifier: Any) {
        guard !cancelled else { return }
        do {
            let id = try identifier(keyIdentifier)
            if renewing { renewedKeys[id] = persistableContentKey }
            else { try FairPlayVault.shared.saveKey(persistableContentKey, assetID: assetID, identifier: id) }
        }
        catch { fail(OfflineError(code: "E_STORAGE", message: "Updated persistent rights could not be saved.")) }
    }
    private func acquire(_ request: AVPersistableContentKeyRequest, identifier: String) async throws -> Data {
        guard let certificateValue = configuration["certificateUrl"]?.string, let certificateURL = URL(string: certificateValue) else {
            throw OfflineError(code: "E_INVALID_DRM", message: "A FairPlay application certificate URL is required.")
        }
        let transport = FairPlayTransport(wifiOnly: wifiOnly)
        let certificate = try await transport.fetch(URLRequest(url: certificateURL), limit: 1024 * 1024)
        let contentID = URL(string: identifier)?.host ?? identifier
        let spc: Data = try await withCheckedThrowingContinuation { continuation in
            request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(contentID.utf8), options: nil) { data, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: OfflineError(code: "E_DRM_LICENSE", message: "AVFoundation could not create a persistent license request.")) }
            }
        }
        try Task.checkCancellation()
        let server = configuration["licenseServer"]?.string ?? ""
        let ckc: Data
        if let callback = configuration["callbackRef"]?.string {
            ckc = try await FairPlayLicenseBroker.shared.request(callbackRef: callback, assetID: assetID, generation: generation,
                spc: spc, contentID: contentID, licenseURL: server, identifier: identifier)
        } else {
            guard let url = URL(string: server), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw OfflineError(code: "E_INVALID_DRM", message: "A FairPlay license server is required.")
            }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = spc
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            for (name, value) in configuration["headers"]?.object ?? [:] { request.setValue(value.string, forHTTPHeaderField: name) }
            ckc = try await transport.fetch(request, limit: 12 * 1024 * 1024)
        }
        try Task.checkCancellation()
        do { return try request.persistableContentKey(fromKeyVendorResponse: ckc, options: nil) }
        catch { throw OfflineError(code: "E_DRM_LICENSE", message: "The provider did not authorize a persistent FairPlay license.") }
    }
    private func deliver(_ identifier: String, result: Result<Data, Error>) {
        tasks.removeValue(forKey: identifier)
        let requests = recipients.removeValue(forKey: identifier) ?? []
        guard !cancelled else { return }
        do {
            let persistent = try result.get()
            if renewing { renewedKeys[identifier] = persistent }
            else { try FairPlayVault.shared.saveKey(persistent, assetID: assetID, identifier: identifier) }
            requests.forEach { $0.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistent)) }
        } catch { requests.forEach { reject($0, error) } }
    }
    private func identifier(_ value: Any?) throws -> String {
        let result = (value as? URL)?.absoluteString ?? value as? String
        guard let result, !result.isEmpty else { throw OfflineError(code: "E_DRM_LICENSE", message: "The native FairPlay content identifier is invalid.") }
        return result
    }
    private func native(_ error: OfflineError) -> NSError { NSError(domain: "StreamDownloader.FairPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: error.message]) }
    private func reject(_ request: AVContentKeyRequest, _ error: Error) {
        let value = error as? OfflineError ?? OfflineError.media(error)
        request.processContentKeyResponseError(native(value)); fail(value)
    }
    private func fail(_ error: OfflineError) { if failure == nil { failure = error; onFailure?(error) } }
    deinit { keySession.expire() }
}

/// Never forward application license headers to a different redirect origin.
private final class FairPlayTransport: NSObject, URLSessionTaskDelegate {
    private let wifiOnly: Bool
    init(wifiOnly: Bool) { self.wifiOnly = wifiOnly }
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.allowsCellularAccess = !wifiOnly
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let retryable = status == 408 || status == 429 || (500...599).contains(status)
            throw OfflineError(code: retryable ? "E_DRM_LICENSE_REQUEST" : "E_DRM_LICENSE", message: "The certificate or license server rejected the request.", retryable: retryable)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw OfflineError(code: "E_DRM_LICENSE", message: "The certificate or license response exceeds the supported size.") }
            data.append(byte)
        }
        guard !data.isEmpty else { throw OfflineError(code: "E_DRM_LICENSE", message: "The certificate or license server returned an empty response.") }
        return data
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let previous = task.originalRequest?.url, next = request.url
        let sameOrigin = previous?.scheme == next?.scheme && previous?.host == next?.host && previous?.port == next?.port
        completionHandler(sameOrigin ? request : nil)
    }
}
