import Foundation
import XCTest
@testable import StreamDownloaderCore

final class SQLiteStoreTests: XCTestCase {
    func testActualSQLiteReopenPreservesMetadataStatesAndExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-downloader-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let options: [String: JSONValue] = ["metadata": .object(["title": .string("Тест"), "nested": .array([.number(1), .bool(true), .null])])]
        let record = DownloadRecord(id: "a", url: "https://media.test/a.mp4", options: options, fingerprint: "hash", order: 1, state: .paused, progress: 0.5, received: 50, total: 100, expiresAt: 1234, stopIntent: "pause")
        var store: SQLiteStore? = try SQLiteStore(directory: directory)
        try store!.put(record); try store!.setEnabled(true); store = nil
        let reopened = try SQLiteStore(directory: directory)
        let loaded = try XCTUnwrap(reopened.load().first)
        XCTAssertEqual(loaded.options, options); XCTAssertEqual(loaded.state, .paused); XCTAssertEqual(loaded.expiresAt, 1234)
        XCTAssertEqual(loaded.progress, 0.5); XCTAssertEqual(loaded.stopIntent, "pause")
        try reopened.remove("a"); XCTAssertTrue(try reopened.load().isEmpty)
    }
    func testJSONDistinguishesBooleansAndRejectsNonFiniteNumbers() throws {
        XCTAssertEqual(try JSONValue(true), .bool(true)); XCTAssertEqual(try JSONValue(1), .number(1))
        XCTAssertThrowsError(try JSONValue(Double.infinity))
        XCTAssertThrowsError(try JSONValue(Date()))
    }
}
