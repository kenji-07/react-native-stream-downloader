import XCTest
@testable import StreamDownloaderCore

final class MediaFailureTests: XCTestCase {
    func testDiskFullSurvivesNestedNativeErrors() {
        let disk = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: disk])
        XCTAssertEqual(OfflineError.media(outer).code, "E_INSUFFICIENT_STORAGE")
    }
    func testNetworkAndStorageFailuresRemainDistinct() {
        XCTAssertEqual(OfflineError.media(URLError(.cannotWriteToFile)).code, "E_STORAGE")
        XCTAssertTrue(OfflineError.media(URLError(.timedOut)).retryable)
        XCTAssertFalse(OfflineError.media(URLError(.serverCertificateUntrusted)).retryable)
        let original = OfflineError(code: "E_INVALID_TRACKS", message: "Selection changed.")
        XCTAssertEqual(OfflineError.media(original).code, original.code)
    }
}
