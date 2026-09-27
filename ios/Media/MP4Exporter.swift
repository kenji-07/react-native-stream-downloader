import Foundation
import AVFoundation

enum MP4Exporter {
    /// AVAssetExportSession is not Sendable. All access after configuration is
    /// confined to this queue, including cancellation and completion inspection.
    private final class ExportOperation: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let queue = DispatchQueue(label: "org.openoffline.mp4-export")
        private var started = false
        private var cancelled = false
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ session: AVAssetExportSession) { self.session = session }
        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else { self.complete(.failure(CancellationError())); return }
                self.started = true
                self.session.exportAsynchronously {
                    self.queue.async {
                        switch self.session.status {
                        case .completed: self.complete(.success(()))
                        case .cancelled: self.complete(.failure(CancellationError()))
                        default: self.complete(.failure(self.session.error.map(OfflineError.media) ?? OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "Native MP4 export failed for the selected track formats.")))
                        }
                    }
                }
            }
        }
        func cancel() { queue.async { self.cancelled = true; if self.started { self.session.cancelExport() } } }
        private func complete(_ result: Result<Void, Error>) {
            let continuation = self.continuation; self.continuation = nil
            continuation?.resume(with: result)
        }
    }
    static func export(sourceURL: URL, selectedTrackIDs: Set<CMPersistentTrackID>, destinationURL: URL) async throws -> Double {
        try Task.checkCancellation()
        let source = AVURLAsset(url: sourceURL)
        guard try await !source.load(.hasProtectedContent) else { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "Encrypted MP4 tracks cannot be exported as clear media.") }
        let tracks = try await source.load(.tracks)
        let selected = tracks.filter { selectedTrackIDs.contains($0.trackID) }
        guard !selected.isEmpty, Set(selected.map(\.trackID)) == selectedTrackIDs else { throw OfflineError(code: "E_INVALID_TRACKS", message: "The MP4 track layout changed during download.") }
        let composition = AVMutableComposition()
        for track in selected {
            try Task.checkCancellation()
            guard [.video, .audio, .text, .subtitle, .closedCaption].contains(track.mediaType),
                  let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "A selected MP4 track cannot be represented in a native composition.")
            }
            let range = try await track.load(.timeRange)
            // Keep each track's original presentation offset and orientation.
            try destination.insertTimeRange(range, of: track, at: range.start)
            destination.preferredTransform = try await track.load(.preferredTransform)
            destination.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            destination.languageCode = try await track.load(.languageCode)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "The selected track formats cannot be exported to MP4 without re-encoding.") }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
        exporter.outputURL = destinationURL; exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        let operation = ExportOperation(exporter)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destinationURL) } }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start(continuation)
                // Close the race between cancellation registration and starting.
                if Task.isCancelled { operation.cancel() }
            }
        }, onCancel: { operation.cancel() })
        try Task.checkCancellation()
        let output = AVURLAsset(url: destinationURL)
        let exported = try await output.load(.tracks)
        let expectedTypes = selected.map { $0.mediaType.rawValue }.sorted()
        guard exported.map({ $0.mediaType.rawValue }).sorted() == expectedTypes else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The exported MP4 does not contain exactly the selected tracks.") }
        let duration = try await output.load(.duration)
        guard duration.seconds.isFinite, duration.seconds >= 0 else { throw OfflineError(code: "E_CORRUPT_ASSET", message: "The exported MP4 has an invalid duration.") }
        complete = true; return (duration.seconds * 1000).rounded(.down)
    }
}
