import Foundation
import AVFoundation

/// Answers `streamdl-key://` AES-128 key requests (`HLSClearKeys`) for a
/// download or an offline player item: from the device-bound Keychain first,
/// otherwise once over HTTPS with the download's headers, then stored.
final class HLSClearKeyLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    private let assetID: String
    private let headers: [String: String]
    private let allowsNetwork: Bool
    private let wifiOnly: Bool
    private let queue = DispatchQueue(label: "org.openoffline.streamdownloader.hls-keys")

    init(assetID: String, headers: [String: String], allowsNetwork: Bool, wifiOnly: Bool) {
        self.assetID = assetID; self.headers = headers; self.allowsNetwork = allowsNetwork; self.wifiOnly = wifiOnly
        super.init()
    }

    /// The resource loader keeps a weak delegate: the owner retains this object
    /// for as long as the asset can request keys.
    func attach(_ asset: AVURLAsset) { asset.resourceLoader.setDelegate(self, queue: queue) }

    /// Fetches every selected rendition's key before the download starts, so a
    /// completed package never depends on the key server again.
    func prefetch(_ uris: Set<String>) async throws {
        for uri in uris.sorted() { try Task.checkCancellation(); _ = try await key(for: uri) }
    }

    func key(for uri: String) async throws -> Data {
        if let stored = try FairPlayVault.shared.clearKey(assetID, uri: uri) { return stored }
        guard allowsNetwork, let url = HLSClearKeys.fetchURL(uri) else {
            throw OfflineError(code: "E_CORRUPT_ASSET", message: "An offline HLS key is missing; download the asset again.")
        }
        var request = URLRequest(url: url); request.allowsCellularAccess = !wifiOnly
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OfflineError(code: "E_NETWORK", message: "The HLS key server returned an unsuccessful response (\(code)).",
                retryable: code == 408 || code == 429 || (500...599).contains(code))
        }
        guard HLSClearKeys.isValidKey(data) else {
            throw OfflineError(code: "E_INVALID_STREAM", message: "The HLS key server did not return a 16-byte AES-128 key.")
        }
        try FairPlayVault.shared.saveClearKey(data, assetID: assetID, uri: uri)
        return data
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, HLSClearKeys.isClearKeyURI(url.absoluteString) else { return false }
        Task {
            do {
                let data = try await key(for: url.absoluteString)
                if let info = loadingRequest.contentInformationRequest {
                    info.contentLength = Int64(data.count); info.isByteRangeAccessSupported = false
                }
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }
}
