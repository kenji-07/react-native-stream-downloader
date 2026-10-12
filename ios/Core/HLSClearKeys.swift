import Foundation

/// Offline AES-128 (`METHOD=AES-128`) HLS keys on iOS.
///
/// AVFoundation never stores AES-128 keys in a downloaded `.movpkg`. At
/// playback it requests the playlist's `https` key URI again: without the
/// download's headers (an authenticated key server answers 401 and the player
/// fails with NSURLError -1013), and not at all without a network. Only a
/// custom URI scheme reaches an `AVAssetResourceLoaderDelegate`, so a server
/// that supports offline AES-128 rewrites its key URIs from `https://` to
/// `streamdl-key://` (same host, path and query) when a playlist request
/// carries `X-Stream-Downloader-Keys: streamdl-key`. The package sends that
/// header on its iOS media requests, fetches each key once over HTTPS with the
/// download's headers, keeps it in the device-bound Keychain and serves it to
/// the offline player.
enum HLSClearKeys {
    static let scheme = "streamdl-key"
    static let capabilityHeader = "X-Stream-Downloader-Keys"

    static func isClearKeyURI(_ uri: String) -> Bool {
        URLComponents(string: uri)?.scheme?.lowercased() == scheme
    }

    /// `streamdl-key://host/path?query` → `https://host/path?query`.
    static func fetchURL(_ uri: String) -> URL? {
        guard var parts = URLComponents(string: uri), parts.scheme?.lowercased() == scheme,
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    /// Storage identity of a key: host and path. The query usually carries a
    /// renewable signature that differs between the download and later reads.
    static func identity(_ uri: String) -> String? {
        guard let url = fetchURL(uri), let host = url.host?.lowercased() else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port + (url.path.isEmpty ? "/" : url.path)
    }

    /// `streamdl-key://` AES-128 key URIs declared by one media playlist.
    static func keyURIs(_ playlist: Data) throws -> Set<String> {
        var result = Set<String>()
        for raw in String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-KEY:"), let colon = line.firstIndex(of: ":") else { continue }
            let values = try HLSManifest.attributes(String(line[line.index(after: colon)...]))
            guard values["METHOD"] == "AES-128", let uri = values["URI"], isClearKeyURI(uri) else { continue }
            guard identity(uri) != nil else {
                throw OfflineError(code: "E_INVALID_STREAM", message: "An offline HLS key URI is invalid.")
            }
            result.insert(uri)
        }
        return result
    }

    /// An AES-128 key is exactly 16 bytes.
    static func isValidKey(_ data: Data) -> Bool { data.count == 16 }
}
