import Foundation

enum MediaFilename {
    /// Titles are display data, never paths. Each file is already scoped to its
    /// asset UUID; a suffix keeps the published file separate from raw input.
    static func mp4(title: String?, selected: Bool) -> String {
        guard let title else { return selected ? "selected.mp4" : "video.mp4" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe = String(String.UnicodeScalarView(title.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        guard !safe.isEmpty else { return selected ? "selected.mp4" : "video.mp4" }
        // Limit UTF-8 filename bytes even for multi-byte scripts.
        var prefix = ""
        for character in safe {
            let next = prefix + String(character)
            if next.utf8.count > 180 { break }
            prefix = next
        }
        return prefix + "-offline.mp4"
    }
}
