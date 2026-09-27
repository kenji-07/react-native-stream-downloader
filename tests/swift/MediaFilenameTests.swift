import XCTest
@testable import StreamDownloaderCore

final class MediaFilenameTests: XCTestCase {
    func testTitleCannotEscapeAssetDirectoryOrReplaceRawInput() {
        let name = MediaFilename.mp4(title: "../../video", selected: true)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(".."))
        XCTAssertEqual(name, "video-offline.mp4")
        XCTAssertEqual(MediaFilename.mp4(title: "video", selected: false), "video-offline.mp4")
        XCTAssertEqual(MediaFilename.mp4(title: "///", selected: true), "selected.mp4")
    }
    func testMultibyteTitlesFitFilesystemLimit() {
        let title = String(repeating: "Монгол", count: 50)
        let name = MediaFilename.mp4(title: title, selected: false)
        XCTAssertLessThan(name.utf8.count, 256); XCTAssertTrue(name.hasSuffix("-offline.mp4"))
        XCTAssertTrue(name.hasPrefix("Монгол"))
    }
}
