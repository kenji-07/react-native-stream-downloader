import Foundation
import CryptoKit

enum Validation {
    static func string(_ value: JSONValue?) throws -> String {
        guard let result = value?.string, !result.isEmpty else { throw OfflineError.invalid("Expected a nonempty string.") }; return result
    }
    static func integer(_ value: JSONValue?, min: Double = 0, max: Double = 9007199254740991) throws -> Double {
        guard let result = value?.number, result.isFinite, result.rounded(.towardZero) == result, result >= min, result <= max else { throw OfflineError.invalid("Number is outside the supported integer range.") }; return result
    }
    static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard let result = value?.object else { throw OfflineError.invalid("Expected an object.") }; return result
    }
    static func url(_ value: JSONValue?) throws -> String {
        let text = try string(value)
        guard let parts = URLComponents(string: text), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, (parts.port == nil || (1...65535).contains(parts.port!)), parts.url != nil,
              !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { throw OfflineError(code: "E_INVALID_URL", message: "An HTTP or HTTPS URL without embedded credentials is required.") }
        return text
    }
    static func keys(_ value: [String: JSONValue], _ allowed: Set<String>) throws {
        guard Set(value.keys).subtracting(allowed).isEmpty else { throw OfflineError.invalid("Unsupported object property.") }
    }
    static func params(_ method: String, _ value: [String: JSONValue]) throws -> [String: JSONValue] {
        switch method {
        case "registerPlugin", "disablePlugin", "getConfig", "getDownloadsStatus", "getDownloadedAssets", "cancelAllDownloads", "deleteAllDownloadedAssets", "deleteAllQueuedItems":
            try keys(value, []); return [:]
        case "setConfig":
            let config = try object(value["config"]); try keys(config, ["maxParallelDownloads", "updateFrequencyMS", "wifiOnly", "retry"])
            var normalized = config
            for key in ["maxParallelDownloads", "updateFrequencyMS"] { if let value = config[key] { normalized[key] = .number(try integer(value, min: 1, max: 2147483647)) } }
            if let flag = config["wifiOnly"], flag.bool == nil { throw OfflineError.invalid("wifiOnly must be boolean.") }
            if let value = config["retry"] {
                let retry = try object(value); try keys(retry, ["maxRetries", "initialDelayMS", "maxDelayMS"])
                normalized["retry"] = .object(try Dictionary(uniqueKeysWithValues: retry.map { key, value in
                    (key, JSONValue.number(try integer(value, min: key == "maxRetries" ? 0 : 1, max: key == "maxRetries" ? 10 : 86400000)))
                }))
            }
            return ["config": .object(normalized)]
        case "downloadStream":
            let url = try url(value["url"]); let options = try options(object(value["options"]))
            let canonical = try JSONSerialization.data(withJSONObject: ["url": url, "options": options.mapValues(\.value)], options: [.sortedKeys, .withoutEscapingSlashes])
            let fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            return ["url": .string(url), "options": .object(options), "fingerprint": .string(fingerprint)]
        case "getDRMLicenseStatus":
            try keys(value, ["id"]); return ["id": .string(try string(value["id"]))]
        case "renewDRMLicense":
            try keys(value, ["id", "drm"])
            var result: [String: JSONValue] = ["id": .string(try string(value["id"]))]
            if let drm = value["drm"] { result["drm"] = try options(["drm": drm])["drm"] }
            return result
        case "getAvailableTracks": return ["url": .string(try url(value["url"]))]
        case "expireDownloadedAssetAt": return ["id": .string(try string(value["id"])), "timestamp": .number(try integer(value["timestamp"]))]
        case "cancelDownload", "pauseDownload", "resumeDownload", "getDownloadStatus", "getDownloadedAsset", "deleteDownloadedAsset", "deleteQueuedItem": return ["id": .string(try string(value["id"]))]
        default: throw OfflineError(code: "E_BRIDGE", message: "Unknown native operation.")
        }
    }
    private static func options(_ value: [String: JSONValue]) throws -> [String: JSONValue] {
        try keys(value, ["checkStorageBeforeDownload", "expiresAt", "includeAllTracks", "tracks", "drm", "metadata"])
        var result = value
        for flag in ["checkStorageBeforeDownload", "includeAllTracks"] { if let v = value[flag], v.bool == nil { throw OfflineError.invalid("Download flags must be boolean.") } }
        if let expires = value["expiresAt"] { result["expiresAt"] = .number(try integer(expires)) }
        if let metadata = value["metadata"] {
            let object = try object(metadata)
            if let title = object["title"], title.string == nil { throw OfflineError.invalid("Metadata title must be a string.") }
            let data = try JSONSerialization.data(withJSONObject: object.mapValues(\.value), options: [.withoutEscapingSlashes])
            guard data.count <= 1048576 else { throw OfflineError.invalid("Metadata exceeds 1 MiB.") }
        }
        if let tracks = value["tracks"] {
            let selection = try object(tracks); try keys(selection, ["audio", "video", "text"])
            var normalized: [String: JSONValue] = [:]
            for (type, ids) in selection {
                guard case let .array(items) = ids else { throw OfflineError.invalid("Track IDs must be arrays.") }
                var seen = Set<String>()
                let strings = try items.map { try string($0) }.filter { seen.insert($0).inserted }
                normalized[type] = .array(strings.map { .string($0) })
            }
            guard normalized.count != 3 || normalized.values.contains(where: { $0 != .array([]) }) else { throw OfflineError.invalid("At least one media track must be selected.") }
            result["tracks"] = .object(normalized)
        }
        if let drm = value["drm"] {
            let config = try object(drm); try keys(config, ["certificateUrl", "licenseServer", "callbackRef", "headers"])
            _ = try url(config["certificateUrl"])
            if let server = config["licenseServer"] { _ = try url(server) }
            if let callback = config["callbackRef"] { _ = try string(callback) }
            guard config["licenseServer"] != nil || config["callbackRef"] != nil else { throw OfflineError(code: "E_INVALID_DRM", message: "FairPlay requires a license server or getLicense callback.") }
            if let headers = config["headers"] {
                for (key, item) in try object(headers) {
                    guard key.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil, let text = item.string, !text.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { throw OfflineError(code: "E_INVALID_DRM", message: "DRM headers are invalid.") }
                }
            }
        }
        return result
    }
}
