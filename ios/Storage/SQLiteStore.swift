import Foundation
import SQLite3

final class SQLiteStore: RecordStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        let path = directory.appendingPathComponent("metadata.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw failure()
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY NOT NULL, document BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS configuration (id INTEGER PRIMARY KEY, document BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS settings (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)")
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func failure() -> OfflineError { OfflineError(code: "E_STORAGE", message: "Offline metadata storage failed.") }
    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    func load() throws -> [DownloadRecord] {
        let query = try statement("SELECT document FROM downloads"); defer { sqlite3_finalize(query) }
        var result: [DownloadRecord] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
            do {
                guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure() }
                if let id = document["id"] as? String, var options = document["options"] as? [String: Any], options["drm"] != nil {
                    let configuration: [String: JSONValue]
                    if let saved = try FairPlayVault.shared.configuration(id) { configuration = saved }
                    else if let legacy = options["drm"] as? [String: Any], legacy["protectedConfiguration"] == nil {
                        // Migrate an earlier development database on the next
                        // queue save, dropping any stale JS callback identity.
                        var values = try JSONValue(legacy).object ?? [:]
                        if values.removeValue(forKey: "callbackRef") != nil { values["requiresCallback"] = .bool(true) }
                        configuration = values
                    } else { configuration = ["requiresCallback": .bool(true)] }
                    options["drm"] = try JSONSerialization.jsonObject(with: encoder.encode(JSONValue.object(configuration)))
                    document["options"] = options
                }
                let restored = try JSONSerialization.data(withJSONObject: document)
                result.append(try decoder.decode(DownloadRecord.self, from: restored))
            }
            catch let error as OfflineError { throw error }
            catch { throw OfflineError(code: "E_CORRUPT_ASSET", message: "Stored download metadata is corrupted.") }
        }
    }
    func put(_ record: DownloadRecord) throws {
        guard var document = try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any] else { throw failure() }
        if let drm = record.options["drm"]?.object {
            try FairPlayVault.shared.saveConfiguration(drm, assetID: record.id)
            guard var options = document["options"] as? [String: Any] else { throw failure() }
            options["drm"] = try JSONSerialization.jsonObject(with: encoder.encode(JSONValue.object(["protectedConfiguration": .bool(true)])))
            document["options"] = options
        }
        let data = try JSONSerialization.data(withJSONObject: document)
        let query = try statement("INSERT OR REPLACE INTO downloads (id, document) VALUES (?, ?)"); defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, record.id, -1, transient) == SQLITE_OK else { throw failure() }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32(data.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    func remove(_ id: String) throws {
        let query = try statement("DELETE FROM downloads WHERE id = ?"); defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, id, -1, transient) == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    func configuration() throws -> [String: JSONValue] {
        let query = try statement("SELECT document FROM configuration WHERE id = 1"); defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return [:] }
        guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
        return try decoder.decode([String: JSONValue].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
    }
    func setConfiguration(_ value: [String: JSONValue]) throws {
        let data = try encoder.encode(value)
        let query = try statement("INSERT OR REPLACE INTO configuration (id, document) VALUES (1, ?)"); defer { sqlite3_finalize(query) }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32(data.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    func enabled() throws -> Bool {
        let query = try statement("SELECT value FROM settings WHERE name = 'enabled'"); defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return false }
        guard code == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(query, 0) == 1
    }
    func setEnabled(_ enabled: Bool) throws {
        try execute("INSERT OR REPLACE INTO settings (name, value) VALUES ('enabled', \(enabled ? 1 : 0))")
    }
}
