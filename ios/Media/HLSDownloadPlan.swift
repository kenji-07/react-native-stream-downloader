import Foundation
import AVFoundation

struct HLSDownloadPlan {
    let configuration: AVAssetDownloadConfiguration
    let variants: [AVAssetVariant]
    let duration: Double
    let estimatedBytes: Int64?
    let keyIdentifiers: Set<String>
    let requiresDRM: Bool

    static func prepare(_ inspection: MediaInspection, options: [String: JSONValue], title: String,
                        prepareAsset: ((AVURLAsset) -> Void)? = nil) async throws -> HLSDownloadPlan {
        guard let manifest = inspection.manifest else { throw OfflineError(code: "E_MANIFEST", message: "An HLS playlist is required.") }
        var requiresDRM = !manifest.isMaster && manifest.needsDRM
        var keyIdentifiers = Set<String>()
        if requiresDRM && options["drm"] == nil { throw OfflineError(code: "E_DRM_REQUIRED", message: "Encrypted HLS requires persistent FairPlay configuration.") }
        let headers = NativeMediaCatalog.headers(options)
        let (rootData, rootURL) = try await NativeMediaCatalog.read(inspection.asset.url, wifiOnly: options["_wifiOnly"]?.bool ?? false, headers: headers)
        let currentRoot = try HLSManifest(data: rootData, baseURL: rootURL)
        guard currentRoot.fingerprint == manifest.fingerprint else {
            throw OfflineError(code: "E_INVALID_TRACKS", message: "The HLS playlist changed during track preparation.")
        }
        // A master may advertise session keys for unselected variants. Acquire
        // the key URIs in selected media playlists, where encryption applies.
        // Media-playlist input has no child pass, so inspect its keys here.
        if !manifest.isMaster { keyIdentifiers.formUnion(try fairPlayIdentifiers(rootData)) }
        let asset = inspection.asset
        let nativeVariants = try await asset.load(.variants)
        let selected: [HLSManifest.Track]
        let variants: [AVAssetVariant]
        var duration = manifest.duration
        if manifest.isMaster {
            selected = try manifest.select(options)
            let descriptors = selected.filter(\.isVariant)
            guard !descriptors.isEmpty else { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "This HLS selection must retain a playable variant.") }
            variants = try descriptors.map { try match($0, in: nativeVariants) }
            guard Set(variants.map(ObjectIdentifier.init)).count == variants.count else { throw ambiguous("Several HLS descriptors map to the same native variant.") }
            let urls = Set(selected.compactMap(\.uri))
            for url in urls {
                try Task.checkCancellation()
                let (data, base) = try await NativeMediaCatalog.read(url, wifiOnly: options["_wifiOnly"]?.bool ?? false, headers: headers)
                let child = try HLSManifest(data: data, baseURL: base)
                guard !child.isMaster, child.finite else { throw OfflineError(code: "E_UNSUPPORTED_MEDIA", message: "Each selected HLS rendition must be a finite VOD playlist.") }
                if child.needsDRM {
                    requiresDRM = true
                    guard options["drm"] != nil else { throw OfflineError(code: "E_DRM_REQUIRED", message: "Encrypted HLS requires persistent FairPlay configuration.") }
                }
                keyIdentifiers.formUnion(try fairPlayIdentifiers(data))
                duration = max(duration, child.duration)
            }
            try await verifyEmbeddedSelections(descriptors, selected: selected, options: options, prepareAsset: prepareAsset)
        } else {
            selected = []
            let requested = options["tracks"]?.object ?? [:]
            for (type, value) in requested {
                guard case let .array(ids) = value else { throw OfflineError.invalid("Track IDs must be arrays.") }
                let actual = Set(inspection.rows.filter { $0["type"] as? String == type }.compactMap { $0["id"] as? String })
                let chosen = Set(ids.compactMap(\.string))
                guard chosen.isSubset(of: actual) else { throw OfflineError(code: "E_INVALID_TRACKS", message: "A selected track is unknown or belongs to changed media.") }
                guard chosen == actual else { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "Tracks sharing an HLS media playlist cannot be removed without remuxing its segments.") }
            }
            variants = nativeVariants
        }
        guard !variants.isEmpty else { throw OfflineError(code: "E_INVALID_STREAM", message: "AVFoundation did not expose a downloadable HLS variant.") }
        let config = AVAssetDownloadConfiguration(asset: asset, title: title)
        config.auxiliaryContentConfigurations = []
        config.optimizesAuxiliaryContentConfigurations = false
        for (index, variant) in variants.enumerated() {
            let content = index == 0 ? config.primaryContentConfiguration : AVAssetDownloadContentConfiguration()
            content.variantQualifiers = [AVAssetVariantQualifier(variant: variant)]
            content.mediaSelections = try await selections(asset, selected: selected, manifest: manifest, options: options, variant: manifest.isMaster ? selected.filter(\.isVariant)[index] : nil)
            if index > 0 { config.auxiliaryContentConfigurations.append(content) }
        }
        let bitrate = variants.reduce(0.0) { $0 + max(0, $1.peakBitRate ?? 0, $1.averageBitRate ?? 0) }
        let estimate = bitrate * duration / 8000
        return HLSDownloadPlan(configuration: config, variants: variants, duration: duration,
            estimatedBytes: estimate.isFinite && estimate > 0 && estimate < Double(Int64.max) ? Int64(estimate.rounded(.up)) : nil,
            keyIdentifiers: keyIdentifiers, requiresDRM: requiresDRM)
    }

    private static func fairPlayIdentifiers(_ data: Data) throws -> Set<String> {
        var result = Set<String>()
        for rawLine in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:"), let colon = line.firstIndex(of: ":") else { continue }
            let values = try HLSManifest.attributes(String(line[line.index(after: colon)...]))
            guard values["METHOD"] != "NONE" else { continue }
            let format = values["KEYFORMAT"] ?? "identity"
            if format != "identity" && format != "com.apple.streamingkeydelivery" { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "The selected HLS key format is not FairPlay.") }
            guard format == "com.apple.streamingkeydelivery" else {
                if values["METHOD"]?.hasPrefix("SAMPLE-AES") == true { throw OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: "Sample-encrypted HLS requires the FairPlay key format on iOS.") }
                continue
            }
            guard values["METHOD"] == "SAMPLE-AES", let identifier = values["URI"], let url = URL(string: identifier), url.scheme?.lowercased() == "skd" else { throw OfflineError(code: "E_INVALID_DRM", message: "The selected FairPlay key URI or encryption method is invalid.") }
            result.insert(identifier)
        }
        return result
    }

    private static func verifyEmbeddedSelections(_ variants: [HLSManifest.Track], selected: [HLSManifest.Track],
                                                  options: [String: JSONValue], prepareAsset: ((AVURLAsset) -> Void)?) async throws {
        let requested = options["tracks"]?.object ?? [:]
        guard requested["audio"] != nil || requested["text"] != nil else { return }
        for variant in variants {
            let excludedTypes = ["audio", "text"].filter { type in
                guard requested[type] != nil else { return false }
                if type == "audio", variant.type == "audio" { return false }
                // A selected in-band descriptor authorizes its shared bytes.
                return !selected.contains { track in
                    guard track.type == type, track.embedded, !track.isVariant else { return false }
                    if let parent = track.parentVariant { return parent == variant.id }
                    return track.group == variant.attributes[type == "audio" ? "AUDIO" : "CLOSED-CAPTIONS"]
                }
            }
            guard !excludedTypes.isEmpty, let url = variant.uri else { continue }
            let child = AVURLAsset(url: url, options: NativeMediaCatalog.assetOptions(wifiOnly: options["_wifiOnly"]?.bool ?? false, headers: NativeMediaCatalog.headers(options))); prepareAsset?(child)
            let nativeTracks = try await child.load(.tracks)
            if nativeTracks.contains(where: { track in
                (excludedTypes.contains("audio") && track.mediaType == .audio) ||
                // CEA captions are integral to retained video samples. Native
                // selection can hide them, but downloading a separate WebVTT
                // choice does not require rewriting those video samples.
                (excludedTypes.contains("text") && [.text, .subtitle].contains(track.mediaType))
            }) {
                throw ambiguous("The selected HLS segments contain an unselected in-band track that cannot be removed without remuxing.")
            }
        }
    }

    private static func match(_ descriptor: HLSManifest.Track, in variants: [AVAssetVariant]) throws -> AVAssetVariant {
        let matches = variants.filter { variant in
            if #available(iOS 26.0, macOS 26.0, *), let uri = descriptor.uri,
               HLSManifest.resourceIdentity(variant.url) != HLSManifest.resourceIdentity(uri) { return false }
            if let bandwidth = descriptor.attributes["BANDWIDTH"].flatMap(Double.init), variant.peakBitRate != bandwidth { return false }
            if let average = descriptor.attributes["AVERAGE-BANDWIDTH"].flatMap(Double.init), variant.averageBitRate != average { return false }
            if let resolution = descriptor.attributes["RESOLUTION"]?.split(separator: "x"), resolution.count == 2,
               let width = Double(resolution[0]), let height = Double(resolution[1]) {
                guard variant.videoAttributes?.presentationSize == CGSize(width: width, height: height) else { return false }
            }
            if let fps = descriptor.attributes["FRAME-RATE"].flatMap(Double.init), let native = variant.videoAttributes?.nominalFrameRate,
               abs(native - fps) > 0.01 { return false }
            return true
        }
        guard matches.count == 1 else { throw ambiguous("The selected HLS variant cannot be mapped uniquely on this OS version.") }
        return matches[0]
    }

    private static func selections(_ asset: AVURLAsset, selected: [HLSManifest.Track], manifest: HLSManifest,
                                   options: [String: JSONValue], variant: HLSManifest.Track?) async throws -> [AVMediaSelection] {
        // Cross-product the selected audio/text options. A single automatic
        // selection would silently omit requested languages or subtitle tracks.
        let preferred = try await asset.load(.preferredMediaSelection)
        guard let initial = preferred.mutableCopy() as? AVMutableMediaSelection else { throw ambiguous("A native media selection could not be created.") }
        var combinations = [initial]
        for (type, characteristic) in [("audio", AVMediaCharacteristic.audible), ("text", AVMediaCharacteristic.legible)] {
            guard let group = try await asset.loadMediaSelectionGroup(for: characteristic) else {
                if selected.contains(where: { $0.type == type && !$0.embedded && !$0.isVariant }) { throw ambiguous("A selected HLS rendition is absent from the native media group.") }
                continue
            }
            let descriptors = selected.filter { track in
                guard track.type == type, !track.isVariant else { return false }
                guard let variant else { return true }
                if let parent = track.parentVariant { return parent == variant.id }
                return track.group == variant.attributes[type == "audio" ? "AUDIO" : "SUBTITLES"] || type == "text" && track.group == variant.attributes["CLOSED-CAPTIONS"]
            }
            let requested = options["tracks"]?.object?[type]
            var choices: [AVMediaSelectionOption?]
            if !manifest.isMaster || type == "audio" && variant?.type == "audio" { choices = group.options.map { $0 } }
            else if !descriptors.isEmpty && descriptors.allSatisfy({ $0.embedded && $0.parentVariant != nil }) {
                // A CODECS-derived row describes muxed audio carried by the
                // variant, not one separately selectable native language.
                choices = group.options.map { $0 }
            }
            else if !descriptors.isEmpty {
                let nativeOptions = group.options
                let candidates = try await renditionCandidates(nativeOptions)
                let selectedOptions = try descriptors.map { nativeOptions[try HLSRenditionMatcher.index(attributes: $0.attributes, candidates: candidates)] }
                guard Set(selectedOptions.map(ObjectIdentifier.init)).count == selectedOptions.count else {
                    throw ambiguous("Several selected HLS renditions map to the same native media option.")
                }
                choices = selectedOptions.map { $0 }
            }
            else if case .array([])? = requested {
                guard group.allowsEmptySelection else { throw ambiguous("This HLS media group cannot be physically excluded.") }
                choices = [nil]
            } else if requested == nil { choices = group.options.map { $0 } }
            else { throw ambiguous("The selected HLS rendition cannot be mapped to this native variant.") }
            if choices.isEmpty { choices = [nil] }
            var next: [AVMutableMediaSelection] = []
            for selection in combinations {
                for option in choices {
                    guard let copy = selection.mutableCopy() as? AVMutableMediaSelection else { throw ambiguous("A native media selection could not be copied.") }
                    copy.select(option, in: group); next.append(copy)
                }
            }
            combinations = next
        }
        return combinations
    }

    private static func renditionCandidates(_ options: [AVMediaSelectionOption]) async throws -> [HLSRenditionMatcher.Candidate] {
        var candidates: [HLSRenditionMatcher.Candidate] = []
        for (index, option) in options.enumerated() {
            try Task.checkCancellation()
            let kind: HLSRenditionMatcher.Kind
            switch option.mediaType {
            case .audio: kind = .audio
            case .closedCaption: kind = .closedCaption
            case .subtitle, .text: kind = .subtitle
            default: kind = .other
            }
            var titles = Set<String>()
            for item in AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle) {
                if let title = try await item.load(.stringValue), !title.isEmpty { titles.insert(title) }
            }
            let characteristics = Set(HLSRenditionMatcher.knownCharacteristics.filter {
                option.hasMediaCharacteristic(AVMediaCharacteristic(rawValue: $0))
            })
            candidates.append(.init(index: index, kind: kind, language: option.extendedLanguageTag ?? option.locale?.identifier,
                titles: titles, displayName: option.displayName,
                forced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles), characteristics: characteristics))
        }
        return candidates
    }
    private static func ambiguous(_ message: String) -> OfflineError { OfflineError(code: "E_UNSUPPORTED_CAPABILITY", message: message) }
}
