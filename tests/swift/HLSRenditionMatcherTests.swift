import XCTest
@testable import StreamDownloaderCore

final class HLSRenditionMatcherTests: XCTestCase {
    private func option(_ index: Int, _ kind: HLSRenditionMatcher.Kind = .audio, language: String = "en",
                        title: String? = nil, display: String = "English", forced: Bool = false,
                        characteristics: Set<String> = []) -> HLSRenditionMatcher.Candidate {
        .init(index: index, kind: kind, language: language, titles: Set(title.map { [$0] } ?? []),
            displayName: display, forced: forced, characteristics: characteristics)
    }

    func testAngelStereoAndSurroundMatchOriginalTitleInsteadOfDisplayName() throws {
        let candidates = [option(0, title: "stream_5"), option(1, title: "stream_6", display: "stream_6 - English")]
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "LANGUAGE": "en", "NAME": "stream_5"], candidates: candidates), 0)
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "LANGUAGE": "en", "NAME": "stream_6"], candidates: candidates), 1)
    }

    func testClassicOriginalTitlesAndLanguageAliases() throws {
        let candidates = [option(0, language: "eng", title: "BipBop Audio 1"), option(1, language: "eng", title: "BipBop Audio 2", display: "BipBop Audio 2 - English")]
        XCTAssertEqual(HLSRenditionMatcher.canonicalLanguage("eng"), HLSRenditionMatcher.canonicalLanguage("en"))
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "LANGUAGE": "en", "NAME": "BipBop Audio 1"], candidates: candidates), 0)
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "LANGUAGE": "eng", "NAME": "BipBop Audio 2"], candidates: candidates), 1)
    }

    func testShowcaseClosedCaptionAndWebVTTKeepDistinctMediaTypes() throws {
        let candidates = [option(0, .closedCaption, title: "English", display: "English CC"), option(1, .subtitle, title: "English")]
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "CLOSED-CAPTIONS", "LANGUAGE": "en", "NAME": "English"], candidates: candidates), 0)
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "SUBTITLES", "LANGUAGE": "en", "NAME": "English"], candidates: candidates), 1)
    }

    func testForcedAndAccessibilityCharacteristicsDisambiguateSubtitles() throws {
        let sdh: Set<String> = ["public.accessibility.transcribes-spoken-dialog", "public.accessibility.describes-music-and-sound"]
        let candidates = [option(0, .subtitle, title: "English"), option(1, .subtitle, title: "English", display: "English SDH", characteristics: sdh),
            option(2, .subtitle, title: "English", display: "English Forced", forced: true)]
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "SUBTITLES", "NAME": "English", "FORCED": "YES"], candidates: candidates), 2)
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "SUBTITLES", "NAME": "English", "CHARACTERISTICS": sdh.sorted().joined(separator: ",")], candidates: candidates), 1)
    }

    func testLocaleNormalizationKeepsRegionalLanguageDistinctions() throws {
        let candidates = [option(0, language: "pt-BR", title: "Portuguese"), option(1, language: "pt-PT", title: "Portuguese")]
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "LANGUAGE": "pt_BR", "NAME": "Portuguese"], candidates: candidates), 0)
    }

    func testDuplicateMetadataStillRejectsAndMissingTitlesUseDisplayFallback() throws {
        let duplicate = [option(0, title: "English"), option(1, title: "English")]
        XCTAssertThrowsError(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "NAME": "English", "LANGUAGE": "en"], candidates: duplicate))
        XCTAssertThrowsError(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "NAME": "Missing", "LANGUAGE": "en"], candidates: [option(0, title: "Other")]))
        XCTAssertEqual(try HLSRenditionMatcher.index(attributes: ["TYPE": "AUDIO", "NAME": "English", "LANGUAGE": "en"], candidates: [option(0), option(1, language: "de", display: "German")]), 0)
    }
}
