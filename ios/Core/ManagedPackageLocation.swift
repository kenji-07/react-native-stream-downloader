import Foundation

/// AVFoundation can report /private/var paths while the app container uses the
/// /var symlink. Compare real paths, then persist only the container-relative
/// suffix so a restored app can resolve its new container location.
enum ManagedPackageLocation {
    static func relativePath(of package: URL, under container: URL) throws -> String {
        guard package.isFileURL, container.isFileURL else {
            throw OfflineError(code: "E_STORAGE", message: "AVFoundation returned a non-file package location.")
        }
        let root = try canonical(container).pathComponents
        let target = try canonical(package).pathComponents
        guard target.count > root.count, Array(target.prefix(root.count)) == root else {
            throw OfflineError(code: "E_STORAGE", message: "AVFoundation returned a package location outside the app container.")
        }
        return target.dropFirst(root.count).joined(separator: "/")
    }

    static func resolve(_ relativePath: String, under container: URL) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard container.isFileURL, !relativePath.hasPrefix("/"),
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        guard let root = try? canonical(container),
              let package = try? canonical(root.appendingPathComponent(relativePath)) else { return nil }
        guard (try? self.relativePath(of: package, under: root)) != nil else { return nil }
        return package
    }

    private static func canonical(_ url: URL, linkDepth: Int = 0) throws -> URL {
        guard linkDepth < 40 else {
            throw OfflineError(code: "E_STORAGE", message: "The HLS package location contains an unresolved symbolic link.")
        }
        let manager = FileManager.default
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        // resolvingSymlinksInPath leaves the whole URL unchanged if its leaf
        // does not exist. willDownloadTo often precedes package creation, so
        // resolve an existing ancestor and append the not-yet-created suffix.
        while !manager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            if let destination = try? manager.destinationOfSymbolicLink(atPath: ancestor.path) {
                // Also resolve dangling links; otherwise a future package
                // could escape the container when that link's target appears.
                let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) :
                    ancestor.deletingLastPathComponent().appendingPathComponent(destination)
                ancestor = try canonical(target, linkDepth: linkDepth + 1)
                break
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        return suffix.reversed().reduce(resolved) { $0.appendingPathComponent($1) }
    }
}
