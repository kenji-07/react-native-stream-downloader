import Foundation
import CryptoKit

/// Public track descriptors come from the playlist; native AVFoundation objects
/// are matched separately before configuring a download.
struct HLSManifest {
    struct Track {
        let id: String
        let type: String
        let uri: URL?
        let attributes: [String: String]
        let embedded: Bool
        var parentVariant: String? = nil
        var isVariant = false
        var intrinsicCaptions: Bool { attributes["TYPE"] == "CLOSED-CAPTIONS" }
        var group: String { attributes["GROUP-ID"] ?? "" }
        func publicValue(baseURL: URL) -> [String: Any] {
            var value: [String: Any] = ["id": id, "type": type, "uri": (uri ?? baseURL).absoluteString]
            if type == "video" {
                value["bandwidth"] = Double(attributes["BANDWIDTH"] ?? "") ?? 0
                if let resolution = attributes["RESOLUTION"]?.split(separator: "x"), resolution.count == 2,
                   let width = Int(resolution[0]), let height = Int(resolution[1]), width > 0, height > 0 {
                    value["resolution"] = ["width": width, "height": height]
                }
                for (attribute, field) in [("CODECS", "codecs"), ("AUDIO", "audioGroupId"), ("SUBTITLES", "subtitlesGroupId"), ("CLOSED-CAPTIONS", "captionGroupId"), ("VIDEO", "videoGroupId"), ("NAME", "label")] {
                    if let item = attributes[attribute] { value[field] = item }
                }
            } else {
                value["groupId"] = group; value["name"] = attributes["NAME"] ?? type
                value["language"] = attributes["LANGUAGE"]
                value["isDefault"] = attributes["DEFAULT"] == "YES"
                value["autoSelect"] = attributes["AUTOSELECT"] == "YES"
                if type == "text" { value["forced"] = attributes["FORCED"] == "YES" }
            }
            return value
        }
    }
    let baseURL: URL
    let fingerprint: String
    let tracks: [Track]
    let isMaster: Bool
    let finite: Bool
    let duration: Double // milliseconds
    let needsDRM: Bool

    init(data: Data, baseURL: URL) throws {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw Self.invalid("The HLS manifest is invalid or exceeds 8 MiB.") }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw Self.invalid("The response is not an HLS playlist.") }
        // Track identity follows playback structure, not analytics comments or
        // a CDN's renewable URL signature. Requests still use the original URL.
        let canonical = try lines.compactMap { line -> String? in
            if line.hasPrefix("#EXT-X-SESSION-DATA:") { return nil }
            if line.hasPrefix("#") && !line.hasPrefix("#EXT") { return nil }
            if !line.hasPrefix("#") { return Self.resourceIdentity(try Self.resolve(line, baseURL)) }
            let uriTags = ["#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-IMAGE-STREAM-INF:"]
            if let tag = uriTags.first(where: { line.hasPrefix($0) }) {
                let attributes = try Self.attributes(String(line.dropFirst(tag.count)))
                return tag + (try attributes.keys.sorted().map { key in
                    let value = attributes[key]!
                    return key + "=" + (key == "URI" ? Self.resourceIdentity(try Self.resolve(value, baseURL)) : value)
                }).joined(separator: "\u{0}")
            }
            return line
        }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(Self.resourceIdentity(baseURL).utf8) + Data([0]) + Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        var tracks: [Track] = []; var pending: [String: String]?
        var seconds = 0.0; var finite = false; var master = false; var drm = false; var segments = 0
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-DEFINE:") { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "HLS variable substitution is not supported by this descriptor parser.") }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard pending == nil else { throw Self.invalid("An HLS variant URI is missing.") }
                master = true; pending = try Self.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let bitrate = pending?["BANDWIDTH"].flatMap(Double.init), bitrate.isFinite, bitrate >= 0 else { throw Self.invalid("An HLS variant has an invalid bandwidth.") }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                master = true
                let values = try Self.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                let type: String
                switch values["TYPE"] { case "AUDIO": type = "audio"; case "SUBTITLES", "CLOSED-CAPTIONS": type = "text"; case "VIDEO": continue; default: throw Self.invalid("An HLS rendition has an invalid type.") }
                guard values["GROUP-ID"]?.isEmpty == false, values["NAME"]?.isEmpty == false else { throw Self.invalid("An HLS rendition is missing its group or name.") }
                let uri = try values["URI"].map { try Self.resolve($0, baseURL) }
                if values["TYPE"] == "SUBTITLES" && uri == nil { throw Self.invalid("A subtitle rendition is missing its URI.") }
                tracks.append(Track(id: "\(hash):r:\(tracks.count)", type: type, uri: uri, attributes: values, embedded: uri == nil))
            } else if line.hasPrefix("#EXTINF:") {
                guard let duration = line.dropFirst(8).split(separator: ",", maxSplits: 1).first.flatMap({ Double($0) }), duration.isFinite, duration >= 0 else { throw Self.invalid("An HLS segment duration is invalid.") }
                seconds += duration
            } else if line == "#EXT-X-ENDLIST" { finite = true }
            else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let values = try Self.attributes(String(line.split(separator: ":", maxSplits: 1)[1]))
                if let format = values["KEYFORMAT"], format != "identity" { drm = true }
                if values["METHOD"]?.hasPrefix("SAMPLE-AES") == true { drm = true }
            } else if !line.hasPrefix("#") {
                if let values = pending {
                    let codecs = values["CODECS"]?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).split(separator: ".").first.map(String.init) ?? "" } ?? []
                    let audioOnly = values["RESOLUTION"] == nil && !codecs.isEmpty && codecs.allSatisfy { Self.audioCodecs.contains($0) }
                    tracks.append(Track(id: "\(hash):v:\(tracks.count)", type: audioOnly ? "audio" : "video", uri: try Self.resolve(line, baseURL), attributes: values, embedded: false, isVariant: true))
                    pending = nil
                } else { _ = try Self.resolve(line, baseURL); segments += 1 }
            }
        }
        guard pending == nil, master ? tracks.contains(where: { $0.isVariant }) : segments > 0,
              seconds.isFinite else { throw Self.invalid("The HLS playlist is incomplete or empty.") }
        // CODECS can declare muxed audio without a separate EXT-X-MEDIA row.
        // Keep its dependency on the variant so excluding it cannot be faked.
        for variant in tracks.filter({ $0.type == "video" && $0.attributes["AUDIO"] == nil }) {
            let codecs = variant.attributes["CODECS"]?.lowercased().split(separator: ",").map { String($0.split(separator: ".")[0]) } ?? []
            if codecs.contains(where: { Self.audioCodecs.contains($0) }) {
                tracks.append(Track(id: "\(variant.id):inband-audio", type: "audio", uri: variant.uri,
                    attributes: ["NAME": "Embedded audio"], embedded: true, parentVariant: variant.id))
            }
        }
        self.baseURL = baseURL; fingerprint = hash; self.tracks = tracks; isMaster = master
        self.finite = finite; duration = seconds * 1000; needsDRM = drm
    }

    func select(_ options: [String: JSONValue]) throws -> [Track] {
        let requested = options["tracks"]?.object ?? [:]
        var selected = tracks.filter { track in
            guard case let .array(ids)? = requested[track.type] else { return true }
            return ids.contains(.string(track.id))
        }
        for (type, value) in requested {
            guard case let .array(ids) = value, ids.allSatisfy({ id in tracks.contains { $0.type == type && .string($0.id) == id } }) else { throw OfflineError(code: "E_INVALID_TRACKS", message: "A selected track is unknown or belongs to a changed manifest.") }
        }
        guard !selected.isEmpty else { throw OfflineError(code: "E_INVALID_TRACKS", message: "The selection contains no downloadable tracks.") }
        let variants = selected.filter { $0.isVariant }
        let variantIDs = Set(variants.map(\.id))
        let audioGroups = Set(variants.compactMap { $0.attributes["AUDIO"] })
        let textGroups = Set(variants.compactMap { $0.attributes["SUBTITLES"] } + variants.compactMap { $0.attributes["CLOSED-CAPTIONS"] })
        let incompatible = selected.filter { track in
            if let parent = track.parentVariant { return !variantIDs.contains(parent) }
            return !variants.isEmpty && !track.isVariant && !(track.type == "audio" ? audioGroups : textGroups).contains(track.group)
        }
        // Passing every inspected audio/text ID means all compatible renditions
        // for the chosen variants. This also discards muxed-audio descriptors
        // belonging to video variants that will not be downloaded.
        func requestsAll(_ type: String) -> Bool {
            guard case let .array(ids)? = requested[type] else { return true }
            return Set(ids.compactMap(\.string)) == Set(tracks.filter { $0.type == type }.map(\.id))
        }
        if incompatible.contains(where: { !requestsAll($0.type) }) { throw OfflineError(code: "E_INVALID_TRACKS", message: "The selected HLS renditions do not belong to the chosen variant groups.") }
        let incompatibleIDs = Set(incompatible.map(\.id)); selected.removeAll { incompatibleIDs.contains($0.id) }
        let selectedIDs = Set(selected.map(\.id))
        if tracks.contains(where: { $0.embedded && !$0.intrinsicCaptions && !selectedIDs.contains($0.id) && ($0.parentVariant.map { variantIDs.contains($0) } ?? ($0.type == "audio" ? audioGroups : textGroups).contains($0.group)) }) {
            throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "In-band HLS tracks cannot be removed from their shared media segments.")
        }
        return selected
    }

    static func attributes(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]; var cursor = text.startIndex
        while cursor < text.endIndex {
            let keyStart = cursor
            while cursor < text.endIndex && text[cursor] != "=" && text[cursor] != "," { cursor = text.index(after: cursor) }
            guard cursor < text.endIndex, text[cursor] == "=" else { throw invalid("An HLS attribute is malformed.") }
            let key = String(text[keyStart..<cursor]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, values[key] == nil else { throw invalid("An HLS attribute is empty or repeated.") }
            cursor = text.index(after: cursor)
            let value: String
            if cursor < text.endIndex && text[cursor] == "\"" {
                cursor = text.index(after: cursor); let start = cursor
                while cursor < text.endIndex && text[cursor] != "\"" { cursor = text.index(after: cursor) }
                guard cursor < text.endIndex else { throw invalid("An HLS quoted attribute is unterminated.") }
                value = String(text[start..<cursor]); cursor = text.index(after: cursor)
            } else {
                let start = cursor
                while cursor < text.endIndex && text[cursor] != "," { cursor = text.index(after: cursor) }
                value = String(text[start..<cursor]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
            if cursor < text.endIndex {
                guard text[cursor] == "," else { throw invalid("An HLS attribute separator is invalid.") }
                cursor = text.index(after: cursor)
                guard cursor < text.endIndex else { throw invalid("An HLS attribute is missing after a comma.") }
            }
        }
        return values
    }
    static func resourceIdentity(_ url: URL) -> String {
        // Mux rendition URLs were observed to issue a new signature for the
        // same resource on each master request. Limit normalization to that
        // known transport format; arbitrary tokens/queries can identify media.
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host.hasPrefix("manifest-"), host.hasSuffix(".mux.com"), url.path.hasSuffix("/rendition.m3u8"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true), let items = parts.queryItems,
              items.contains(where: { $0.name == "signature" }), items.contains(where: { $0.name == "expires" }) else { return url.absoluteString }
        parts.queryItems = items.filter { $0.name != "signature" && $0.name != "expires" }
        return parts.url?.absoluteString ?? url.absoluteString
    }
    private static func resolve(_ value: String, _ base: URL) throws -> URL {
        guard !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw invalid("An HLS media URI is invalid or unsupported.") }
        return url
    }
    private static func invalid(_ message: String) -> OfflineError { OfflineError(code: "E_MANIFEST", message: message) }
    private static let audioCodecs: Set<String> = ["mp4a", "ac-3", "ec-3", "opus", "alac", "flac"]
}
