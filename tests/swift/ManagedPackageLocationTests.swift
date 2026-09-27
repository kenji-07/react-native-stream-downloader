import XCTest
@testable import StreamDownloaderCore

final class ManagedPackageLocationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-location-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testContainerSymlinkAndNativePackageRealPathHaveSameIdentity() throws {
        let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
        let container = base.appendingPathComponent("container", isDirectory: true)
        let library = container.appendingPathComponent("Library/Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("container-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: container)
        // willDownloadTo can arrive before the final package exists.
        let package = library.appendingPathComponent("Кино A.movpkg")
        let expected = "Library/Managed/Кино A.movpkg"
        XCTAssertEqual(try ManagedPackageLocation.relativePath(of: package, under: alias), expected)
        XCTAssertEqual(try ManagedPackageLocation.relativePath(of: alias.appendingPathComponent(expected), under: container), expected)
        XCTAssertEqual(ManagedPackageLocation.resolve(expected, under: alias), package.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testRelativeJournalSurvivesContainerRelocation() throws {
        let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old-container", isDirectory: true)
        let new = base.appendingPathComponent("new-container", isDirectory: true)
        for root in [old, new] { try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true) }
        let relative = try ManagedPackageLocation.relativePath(of: old.appendingPathComponent("Library/movie.movpkg"), under: old)
        XCTAssertEqual(ManagedPackageLocation.resolve(relative, under: new), new.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL)
    }

    func testPackageCannotEscapeContainerViaSymlinkOrSiblingPrefix() throws {
        let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
        let container = base.appendingPathComponent("container", isDirectory: true)
        let sibling = base.appendingPathComponent("container-other", isDirectory: true)
        for root in [container, sibling] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let escape = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sibling)
        XCTAssertThrowsError(try ManagedPackageLocation.relativePath(of: sibling.appendingPathComponent("movie.movpkg"), under: container))
        XCTAssertThrowsError(try ManagedPackageLocation.relativePath(of: escape.appendingPathComponent("movie.movpkg"), under: container))
        XCTAssertNil(ManagedPackageLocation.resolve("linked/movie.movpkg", under: container))
        let dangling = container.appendingPathComponent("future-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: sibling.appendingPathComponent("future"))
        XCTAssertThrowsError(try ManagedPackageLocation.relativePath(of: dangling.appendingPathComponent("movie.movpkg"), under: container))
        XCTAssertNil(ManagedPackageLocation.resolve("future-link/movie.movpkg", under: container))
        for path in ["", "../movie.movpkg", "/Library/movie.movpkg", "Library/../movie.movpkg", "Library//movie.movpkg"] {
            XCTAssertNil(ManagedPackageLocation.resolve(path, under: container))
        }
        XCTAssertThrowsError(try ManagedPackageLocation.relativePath(of: URL(string: "https://example.test/movie.movpkg")!, under: container))
    }
}
