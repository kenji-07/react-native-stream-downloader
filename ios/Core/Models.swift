import Foundation
import CoreFoundation

struct OfflineError: Error, Sendable {
    let code: String
    let message: String
    var retryable = false
    static func invalid(_ message: String) -> OfflineError { OfflineError(code: "E_INVALID_ARGUMENT", message: message) }
}

indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(_ value: Any, depth: Int = 0) throws {
        guard depth <= 64 else { throw OfflineError.invalid("JSON nesting exceeds 64 levels.") }
        switch value {
        case is NSNull: self = .null
        case let text as String: self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { guard number.doubleValue.isFinite else { throw OfflineError.invalid("JSON numbers must be finite.") }; self = .number(number.doubleValue) }
        case let items as [Any]: self = .array(try items.map { try JSONValue($0, depth: depth + 1) })
        case let values as [String: Any]: self = .object(try values.mapValues { try JSONValue($0, depth: depth + 1) })
        default: throw OfflineError.invalid("Unsupported JSON value.")
        }
    }
    var value: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(v): return v
        case let .number(v): return v
        case let .string(v): return v
        case let .array(v): return v.map(\.value)
        case let .object(v): return v.mapValues(\.value)
        }
    }
    var object: [String: JSONValue]? { if case let .object(value) = self { return value }; return nil }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var number: Double? { if case let .number(value) = self { return value }; return nil }
    var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
}

enum DownloadState: String, Codable, Sendable {
    case pending, downloading, paused, completed, failed, removed
    var unfinished: Bool { self == .pending || self == .downloading || self == .paused }
}
struct OfflineAsset: Codable, Sendable { let path: String; let duration: Double; let date: Double }
struct DownloadRecord: Codable, Sendable {
    let id: String
    let url: String
    var options: [String: JSONValue]
    let fingerprint: String
    let order: Int64
    var generation: Int64 = 1
    var state: DownloadState = .pending
    var progress: Double = 0
    var received: Int64?
    var total: Int64?
    var error: String?
    var asset: OfflineAsset?
    var expiresAt: Double = 0
    var disableHeld = false
    var stopIntent: String?
    var retryCount: Int?
    var nextRetryAt: Double?
    var status: [String: Any] {
        var result: [String: Any] = ["id": id, "url": url, "status": state.rawValue, "progress": progress]
        if let received { result["receivedBytes"] = received }; if let total { result["totalBytes"] = total }
        if let retryCount, retryCount > 0 { result["retryCount"] = retryCount }; if let nextRetryAt { result["nextRetryAt"] = nextRetryAt }
        if let error { result["error"] = error }; if let metadata = options["metadata"] { result["metadata"] = metadata.value }
        return result
    }
    var downloadedAsset: [String: Any]? {
        guard let asset else { return nil }
        var result: [String: Any] = ["id": id, "url": url, "pathToFile": asset.path, "title": options["metadata"]?.object?["title"]?.string ?? "", "duration": asset.duration, "downloadDate": asset.date]
        if expiresAt != 0 { result["expiresAt"] = expiresAt }
        if let metadata = options["metadata"] { result["metadata"] = metadata.value }
        return result
    }
}

protocol RecordStore {
    func load() throws -> [DownloadRecord]
    func put(_ record: DownloadRecord) throws
    func remove(_ id: String) throws
    func setEnabled(_ enabled: Bool) throws
    func enabled() throws -> Bool
    func configuration() throws -> [String: JSONValue]
    func setConfiguration(_ value: [String: JSONValue]) throws
}
extension RecordStore {
    func enabled() throws -> Bool { false }
    func configuration() throws -> [String: JSONValue] { [:] }
    func setConfiguration(_ value: [String: JSONValue]) throws {}
}
struct TransferProgress: Sendable { let fraction: Double; let received: Int64?; let total: Int64? }
enum TransferResult: Sendable { case complete(OfflineAsset, Int64?, Int64?), failed(OfflineError), stopped }
protocol MediaTransfer { func stop() }
protocol MediaEngine {
    func start(_ record: DownloadRecord, progress: @escaping (TransferProgress) -> Void, finished: @escaping (TransferResult) -> Void) throws -> MediaTransfer
    func delete(_ record: DownloadRecord) throws
    func delete(_ record: DownloadRecord, beforeRemoving: () throws -> Void) throws
    func valid(_ record: DownloadRecord) -> Bool
    func committed(_ records: [DownloadRecord])
    func setPlaybackEnabled(_ enabled: Bool)
    func resolvedAsset(_ record: DownloadRecord) -> OfflineAsset?
    func setWifiOnly(_ value: Bool)
    func prepareRetry(_ record: DownloadRecord) throws
    func license(_ record: DownloadRecord, renew: Bool, config: [String: JSONValue]?, completion: @escaping (Result<LicenseUpdate, Error>) -> Void)
}
extension MediaEngine {
    func delete(_ record: DownloadRecord, beforeRemoving: () throws -> Void) throws { try beforeRemoving(); try delete(record) }
    func committed(_ records: [DownloadRecord]) {}
    func setPlaybackEnabled(_ enabled: Bool) {}
    func resolvedAsset(_ record: DownloadRecord) -> OfflineAsset? { record.asset }
    func setWifiOnly(_ value: Bool) {}
    func prepareRetry(_ record: DownloadRecord) throws {}
    func license(_ record: DownloadRecord, renew: Bool, config: [String: JSONValue]?, completion: @escaping (Result<LicenseUpdate, Error>) -> Void) { completion(.failure(OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "DRM license management is unavailable."))) }
}

struct DownloadPolicy: Codable {
    var wifiOnly = false
    var maxRetries = 0
    var initialDelayMS = 1000.0
    var maxDelayMS = 30000.0
    func retryDelay(_ count: Int) -> Double { min(maxDelayMS, initialDelayMS * pow(2, Double(max(0, min(10, count - 1))))) }
    var wire: [String: Any] { ["wifiOnly": wifiOnly, "retry": ["maxRetries": maxRetries, "initialDelayMS": initialDelayMS, "maxDelayMS": maxDelayMS]] }
    func updated(_ config: [String: JSONValue]) throws -> DownloadPolicy {
        var next = self
        next.wifiOnly = config["wifiOnly"]?.bool ?? wifiOnly
        let retry = config["retry"]?.object ?? [:]
        next.maxRetries = Int(retry["maxRetries"]?.number ?? Double(maxRetries))
        next.initialDelayMS = retry["initialDelayMS"]?.number ?? initialDelayMS
        next.maxDelayMS = retry["maxDelayMS"]?.number ?? maxDelayMS
        guard (0...10).contains(next.maxRetries), (1...86400000).contains(next.initialDelayMS), (next.initialDelayMS...86400000).contains(next.maxDelayMS) else { throw OfflineError.invalid("Invalid retry policy.") }
        return next
    }
}

struct TransferRate {
    private var samples: [(time: Double, bytes: Int64)] = []
    mutating func record(_ bytes: Int64?, at time: Double) {
        guard let bytes else { samples.removeAll(); return }
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((time, bytes))
        while samples.count > 2 && time - samples[0].time > 5000 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }
    func rate(at time: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time - last.time > 3000 { return 0 }
        guard last.time > first.time else { return nil }
        return max(0, Double(last.bytes - first.bytes) * 1000 / (last.time - first.time))
    }
}
struct LicenseUpdate { let status: [String: Any]?; var asset: OfflineAsset?; var release: () -> Void = {} }
