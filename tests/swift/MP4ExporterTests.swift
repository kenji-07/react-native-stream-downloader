import XCTest
import AVFoundation
@testable import StreamDownloaderCore

final class MP4ExporterTests: XCTestCase {
    private var input: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/media/mp4/multitrack.mp4")
    }
    func testNativeExportRetainsOnlyChosenLanguageAndVideo() async throws {
        let source = AVURLAsset(url: input)
        let tracks = try await source.load(.tracks)
        XCTAssertEqual(tracks.count, 3)
        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let audio = tracks.filter { $0.mediaType == .audio }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("selected.mp4")
        let duration = try await MP4Exporter.export(sourceURL: input, selectedTrackIDs: [video.trackID, audio[1].trackID], destinationURL: output)
        XCTAssertGreaterThanOrEqual(duration, 1900); XCTAssertLessThanOrEqual(duration, 2100)
        let exported = try await AVURLAsset(url: output).load(.tracks)
        XCTAssertEqual(exported.count, 2)
        let remainingAudio = try XCTUnwrap(exported.first { $0.mediaType == .audio })
        let expectedLanguage = try await audio[1].load(.languageCode)
        let actualLanguage = try await remainingAudio.load(.languageCode)
        XCTAssertEqual(actualLanguage, expectedLanguage)
        XCTAssertEqual(expectedLanguage, "mon")
    }
    func testAudioOnlyExportAndInvalidSelection() async throws {
        let source = AVURLAsset(url: input)
        let tracks = try await source.load(.tracks)
        let audio = try XCTUnwrap(tracks.first { $0.mediaType == .audio })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("audio.mp4")
        _ = try await MP4Exporter.export(sourceURL: input, selectedTrackIDs: [audio.trackID], destinationURL: output)
        let remaining = try await AVURLAsset(url: output).load(.tracks)
        XCTAssertEqual(remaining.map(\.mediaType), [.audio])
        do { _ = try await MP4Exporter.export(sourceURL: input, selectedTrackIDs: [9999], destinationURL: directory.appendingPathComponent("invalid.mp4")); XCTFail("Expected an invalid track rejection") }
        catch let error as OfflineError { XCTAssertEqual(error.code, "E_INVALID_TRACKS") }
    }
    func testCancellationLeavesNoPublishedOutput() async throws {
        let tracks = try await AVURLAsset(url: input).load(.tracks)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cancelled.mp4")
        let task = Task { try await MP4Exporter.export(sourceURL: input, selectedTrackIDs: Set(tracks.map(\.trackID)), destinationURL: output) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
