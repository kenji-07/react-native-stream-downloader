import Foundation
import AVFoundation
import CryptoKit

struct MediaInspection {
    let kind: String
    let asset: AVURLAsset
    let manifest: HLSManifest?
    let rows: [[String: Any]]
    var publicTracks: [String: Any] {
        Dictionary(uniqueKeysWithValues: ["video", "audio", "text"].map { type in (type, rows.filter { $0["type"] as? String == type }) })
    }
}

enum NativeMediaCatalog {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    static func read(_ url: URL, prefixOnly: Bool = false, wifiOnly: Bool = false) async throws -> (Data, URL) {
        var request = URLRequest(url: url); request.allowsCellularAccess = !wifiOnly
        if prefixOnly { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OfflineError(code: "E_NETWORK", message: "The media server returned an unsuccessful response.", retryable: code == 408 || code == 429 || (500...599).contains(code))
        }
        let limit = prefixOnly ? 1024 : 8 * 1024 * 1024
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if data.count == limit {
                if prefixOnly { break }
                throw OfflineError(code: "E_MANIFEST", message: "The manifest exceeds the supported 8 MiB size.")
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw OfflineError(code: "E_INVALID_STREAM", message: "The media response is empty.") }
        return (data, response.url ?? url)
    }

    static func inspect(_ url: URL, wifiOnly: Bool = false, prepareAsset: ((AVURLAsset) throws -> Void)? = nil) async throws -> MediaInspection {
        let (prefix, _) = try await read(url, prefixOnly: true, wifiOnly: wifiOnly)
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: !wifiOnly])
        try prepareAsset?(asset)
        if text.hasPrefix("#EXTM3U") {
            let (data, baseURL) = try await read(url, wifiOnly: wifiOnly)
            let manifest = try HLSManifest(data: data, baseURL: baseURL)
            if !manifest.isMaster && !manifest.finite { throw OfflineError(code: "E_UNSUPPORTED_MEDIA", message: "Only finite HLS VOD playlists support offline download.") }
            let rows = manifest.isMaster ? manifest.tracks.map { $0.publicValue(baseURL: baseURL) }
                : try await trackRows(asset, prefix: manifest.fingerprint)
            return MediaInspection(kind: "hls", asset: asset, manifest: manifest, rows: rows)
        }
        if text.hasPrefix("<") { throw OfflineError(code: "E_UNSUPPORTED_PLATFORM", message: "AVFoundation does not provide MPEG-DASH offline downloads on iOS.") }
        guard prefix.count >= 8, ["ftyp", "moov", "mdat", "free", "wide"].contains(String(decoding: prefix[4..<8], as: UTF8.self)) else { throw OfflineError(code: "E_UNSUPPORTED_MEDIA", message: "The response is not a supported HLS or MP4 resource.") }
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8) + prefix).map { String(format: "%02x", $0) }.joined()
        return MediaInspection(kind: "mp4", asset: asset, manifest: nil, rows: try await trackRows(asset, prefix: hash))
    }

    private static func trackRows(_ asset: AVURLAsset, prefix: String) async throws -> [[String: Any]] {
        let tracks = try await asset.load(.tracks)
        var rows: [[String: Any]] = []
        for track in tracks {
            let type: String
            switch track.mediaType { case .video: type = "video"; case .audio: type = "audio"; case .text, .subtitle, .closedCaption: type = "text"; default: continue }
            var row: [String: Any] = ["id": "\(prefix):native:\(track.trackID)", "type": type, "uri": asset.url.absoluteString]
            if type == "video" {
                let bitrate = try await track.load(.estimatedDataRate)
                row["bandwidth"] = bitrate.isFinite ? max(0, Double(bitrate)) : 0
                let size = try await track.load(.naturalSize)
                if size.width > 0 && size.height > 0 { row["resolution"] = ["width": Int(size.width), "height": Int(size.height)] }
            } else {
                row["groupId"] = "native:\(type)"; row["name"] = "\(type) \(track.trackID)"
                let language = try await track.load(.extendedLanguageTag)
                if let language { row["language"] = language }
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw OfflineError(code: "E_INVALID_STREAM", message: "The media contains no supported tracks.") }
        return rows
    }
}
