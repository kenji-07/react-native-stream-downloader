import Foundation

/// Value-only observations of public AVMediaSelectionOption properties. The
/// matcher never depends on AVFoundation's private property-list field names.
enum HLSRenditionMatcher {
    enum Kind: Sendable, Equatable { case audio, subtitle, closedCaption, other }
    struct Candidate: Sendable {
        let index: Int
        let kind: Kind
        let language: String?
        let titles: Set<String>
        let displayName: String
        let forced: Bool
        let characteristics: Set<String>
    }
    static let knownCharacteristics: Set<String> = [
        "public.accessibility.transcribes-spoken-dialog",
        "public.accessibility.describes-music-and-sound",
        "public.accessibility.describes-video",
        "public.easy-to-read",
    ]

    static func index(attributes: [String: String], candidates: [Candidate]) throws -> Int {
        var matches = candidates
        if let type = attributes["TYPE"] {
            switch type {
            case "AUDIO": matches = matches.filter { $0.kind == .audio }
            case "SUBTITLES": matches = matches.filter { $0.kind == .subtitle }
            case "CLOSED-CAPTIONS": matches = matches.filter { $0.kind == .closedCaption }
            default: break
            }
        }
        if let language = attributes["LANGUAGE"] {
            matches = matches.filter { $0.language.map(canonicalLanguage) == canonicalLanguage(language) }
        }
        if attributes["TYPE"] == "SUBTITLES" || attributes["TYPE"] == "CLOSED-CAPTIONS" {
            matches = matches.filter { $0.forced == (attributes["FORCED"] == "YES") }
        }
        let requested = Set((attributes["CHARACTERISTICS"] ?? "").split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }).intersection(knownCharacteristics)
        matches = matches.filter { requested.isSubset(of: $0.characteristics) }
        if let name = attributes["NAME"] {
            // displayName is localized and decorated (e.g. "English SDH").
            // Common title metadata retains the original HLS NAME attribute.
            let titled = matches.filter { $0.titles.contains(name) }
            if !titled.isEmpty { matches = titled }
            else {
                let displayed = matches.filter { $0.displayName == name }
                if !displayed.isEmpty { matches = displayed }
                else if matches.contains(where: { !$0.titles.isEmpty }) { matches = [] }
            }
        }
        guard matches.count == 1 else {
            throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "The selected HLS language or subtitle rendition cannot be mapped uniquely to AVFoundation.")
        }
        return matches[0].index
    }

    static func canonicalLanguage(_ value: String) -> String {
        Locale.canonicalLanguageIdentifier(from: value.replacingOccurrences(of: "_", with: "-")).lowercased()
    }
}
