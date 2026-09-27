import Foundation
import Security
import CryptoKit

/// Only opaque AVFoundation persistable blobs and provider configuration enter
/// this device-bound Keychain. No content key is extracted or serialized.
final class FairPlayVault {
    static let shared = FairPlayVault()
    private let lock = NSRecursiveLock()
    private let service = "org.openoffline.streamdownloader.fairplay"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func read(_ account: String) throws -> Data? {
        var attributes = query(account); attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure() }
        return data
    }
    private func write(_ account: String, _ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account); attributes.forEach { item[$0] = $1 }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }
    func saveConfiguration(_ configuration: [String: JSONValue], assetID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var durable = configuration
        let needsCallback = durable.removeValue(forKey: "callbackRef") != nil || durable["requiresCallback"]?.bool == true
        durable["requiresCallback"] = .bool(needsCallback)
        try write("config:" + assetID, JSONEncoder().encode(durable))
    }
    func configuration(_ assetID: String) throws -> [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try read("config:" + assetID) else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    private func keys(_ assetID: String) throws -> [String: Data] {
        guard let data = try read("keys:" + assetID) else { return [:] }
        return try JSONDecoder().decode([String: Data].self, from: data)
    }
    private func identity(_ identifier: String) -> String { SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined() }
    func key(_ assetID: String, identifier: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return try keys(assetID)[identity(identifier)]
    }
    func saveKey(_ data: Data, assetID: String, identifier: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { throw OfflineError(code: "E_DRM_LICENSE", message: "AVFoundation returned an empty persistable key.") }
        var items = try keys(assetID); items[identity(identifier)] = data
        try write("keys:" + assetID, JSONEncoder().encode(items))
    }
    func storedKeys(_ assetID: String) throws -> [Data] { lock.lock(); defer { lock.unlock() }; return Array(try keys(assetID).values) }
    func replaceKeys(_ values: [String: Data], assetID: String, configuration: [String: JSONValue]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !values.isEmpty, values.values.allSatisfy({ !$0.isEmpty }) else { throw OfflineError(code: "E_DRM_LICENSE", message: "Renewal did not provide every persistent key.") }
        try saveConfiguration(configuration, assetID: assetID)
        try write("keys:" + assetID, JSONEncoder().encode(Dictionary(uniqueKeysWithValues: values.map { (identity($0.key), $0.value) })))
    }
    func hasKeys(_ assetID: String) throws -> Bool { lock.lock(); defer { lock.unlock() }; return try !keys(assetID).isEmpty }
    func hasKeys(_ assetID: String, identifiers: [String]) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let items = try keys(assetID)
        return !identifiers.isEmpty && identifiers.allSatisfy { items[identity($0)]?.isEmpty == false }
    }
    func remove(_ assetID: String) throws {
        lock.lock(); defer { lock.unlock() }
        for prefix in ["keys:", "config:"] {
            let status = SecItemDelete(query(prefix + assetID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
        }
    }
    private func failure() -> OfflineError { OfflineError(code: "E_STORAGE", message: "Protected offline rights storage is unavailable.", retryable: true) }
}
