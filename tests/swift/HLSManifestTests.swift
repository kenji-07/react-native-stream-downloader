import XCTest
@testable import StreamDownloaderCore

final class HLSManifestTests: XCTestCase {
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English, stereo",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="en/list.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Mongolian",LANGUAGE="mn",URI="mn/list.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",URI="sub/list.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="a",SUBTITLES="s"
    low/list.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="a",SUBTITLES="s"
    high/list.m3u8
    """
    func parse(_ text: String) throws -> HLSManifest { try HLSManifest(data: Data(text.utf8), baseURL: URL(string: "https://fixture.test/final/master.m3u8")!) }
    func testQuotedAttributesRelativeURIsAndExactSelection() throws {
        let manifest = try parse(master)
        XCTAssertTrue(manifest.isMaster); XCTAssertEqual(manifest.tracks.count, 5)
        let english = manifest.tracks[0], mongolian = manifest.tracks[1], low = manifest.tracks[3]
        XCTAssertEqual(english.attributes["NAME"], "English, stereo")
        XCTAssertEqual(english.uri?.absoluteString, "https://fixture.test/final/en/list.m3u8")
        let selected = try manifest.select(["includeAllTracks": .bool(true), "tracks": .object(["video": .array([.string(low.id)]), "audio": .array([.string(mongolian.id)]), "text": .array([])])])
        XCTAssertEqual(selected.map(\.id), [mongolian.id, low.id])
        XCTAssertEqual(try manifest.select([:]).count, 5)
    }
    func testRejectsStaleIDsAndMalformedAttributes() throws {
        let original = try parse(master), changed = try parse(master.replacingOccurrences(of: "800000", with: "810000"))
        XCTAssertThrowsError(try changed.select(["tracks": .object(["video": .array([.string(original.tracks[3].id)])])]))
        for attributes in ["NAME=\"unterminated", "NAME=x,", "NAME=x,NAME=y", "NAME", "=x", "NAME=\"x\"junk"] {
            XCTAssertThrowsError(try HLSManifest.attributes(attributes))
        }
    }
    func testFiniteMediaDurationAndFairPlayDetection() throws {
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://content\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXTINF:1.5,\nseg0.ts\n#EXTINF:0.5,\nseg1.ts\n#EXT-X-ENDLIST\n"
        let manifest = try parse(playlist)
        XCTAssertFalse(manifest.isMaster); XCTAssertTrue(manifest.finite); XCTAssertTrue(manifest.needsDRM)
        XCTAssertEqual(manifest.duration, 2000); XCTAssertTrue(manifest.tracks.isEmpty)
        XCTAssertFalse(try parse(playlist.replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")).finite)
    }
    func testRejectsIncompleteAndUnsafeMediaURIs() throws {
        for value in ["#EXTM3U", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1", "#EXTM3U\n#EXTINF:nan,\na.ts", "#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd"] {
            XCTAssertThrowsError(try parse(value))
        }
    }
    func testMuxedAudioCannotBeSilentlyExcluded() throws {
        let playlist = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS=\"avc1.640009,mp4a.40.2\"\nmedia.m3u8\n"
        let manifest = try parse(playlist)
        XCTAssertEqual(manifest.tracks.map(\.type), ["video", "audio"])
        XCTAssertEqual(try manifest.select([:]).count, 2)
        XCTAssertThrowsError(try manifest.select(["tracks": .object(["audio": .array([])])])) { error in
            XCTAssertEqual((error as? OfflineError)?.code, "E_UNSUPPORTED_CAPABILITY")
        }
    }
    func testAudioOnlyVariantIsSelectedAsAudio() throws {
        let manifest = try parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.2\"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"\nhigh.m3u8\n")
        XCTAssertEqual(manifest.tracks.map(\.type), ["audio", "audio"])
        XCTAssertTrue(manifest.tracks.allSatisfy(\.isVariant))
        let selected = try manifest.select(["tracks": .object(["video": .array([]), "audio": .array([.string(manifest.tracks[1].id)])])])
        XCTAssertEqual(selected.map(\.id), [manifest.tracks[1].id])
        XCTAssertEqual(selected[0].publicValue(baseURL: manifest.baseURL)["type"] as? String, "audio")
    }
    func testAllInspectedMuxedAudioIDsFollowChosenVideoVariant() throws {
        let manifest = try parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS=\"avc1.640009,mp4a.40.2\"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200000,CODECS=\"avc1.640009,mp4a.40.2\"\nhigh.m3u8\n")
        let video = manifest.tracks.filter { $0.type == "video" }
        let audio = manifest.tracks.filter { $0.type == "audio" }
        let options: [String: JSONValue] = ["tracks": .object(["video": .array([.string(video[1].id)]), "audio": .array(audio.map { .string($0.id) }), "text": .array([])])]
        let selected = try manifest.select(options)
        XCTAssertEqual(selected.map(\.id), [video[1].id, audio[1].id])
        XCTAssertThrowsError(try manifest.select(["tracks": .object(["video": .array([.string(video[1].id)]), "audio": .array([.string(audio[0].id)])])]))
    }
    func testAllRenditionsSelectOnlyCompatibleGroupsButExplicitMismatchFails() throws {
        let content = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"A\",URI=\"a.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"b\",NAME=\"B\",URI=\"b.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO=\"a\"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"b\"\nhigh.m3u8\n"
        let manifest = try parse(content)
        let selected = try manifest.select(["tracks": .object(["video": .array([.string(manifest.tracks[2].id)]), "audio": .array(manifest.tracks.prefix(2).map { .string($0.id) })])])
        XCTAssertEqual(selected.map(\.id), [manifest.tracks[0].id, manifest.tracks[2].id])
        XCTAssertThrowsError(try manifest.select(["tracks": .object(["video": .array([.string(manifest.tracks[2].id)]), "audio": .array([.string(manifest.tracks[1].id)])])]))
    }
    func testMuxSignatureRotationKeepsIDsAndActualDownloadURL() throws {
        let first = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS=\"avc1.640009,mp4a.40.2\"\nhttps://manifest-edge.fastly.mux.com/content/rendition.m3u8?cdn=fastly&expires=100&skid=default&signature=first\n"
        let second = first.replacingOccurrences(of: "expires=100", with: "expires=200").replacingOccurrences(of: "signature=first", with: "signature=second")
        let a = try parse(first), b = try parse(second)
        XCTAssertEqual(a.fingerprint, b.fingerprint); XCTAssertEqual(a.tracks.map(\.id), b.tracks.map(\.id))
        XCTAssertTrue(b.tracks[0].uri!.absoluteString.contains("signature=second"))
        XCTAssertNotEqual(a.fingerprint, try parse(first.replacingOccurrences(of: "content/rendition", with: "other/rendition")).fingerprint)
        XCTAssertNotEqual(a.fingerprint, try parse(first.replacingOccurrences(of: "skid=default", with: "skid=other")).fingerprint)
        XCTAssertNotEqual(a.fingerprint, try parse(first.replacingOccurrences(of: "BANDWIDTH=100000", with: "BANDWIDTH=200000")).fingerprint)
        let ordinary = first.replacingOccurrences(of: "manifest-edge.fastly.mux.com", with: "media.test")
        XCTAssertNotEqual(try parse(ordinary).fingerprint, try parse(ordinary.replacingOccurrences(of: "signature=first", with: "signature=second")).fingerprint)
    }
    func testNonPlaybackSessionDataDoesNotInvalidateTracksButKeysDo() throws {
        let base = "#EXTM3U\n#EXT-X-SESSION-DATA:DATA-ID=\"analytics\",VALUE=\"one\"\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://key-one\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nmedia.m3u8\n"
        XCTAssertEqual(try parse(base).fingerprint, try parse(base.replacingOccurrences(of: "VALUE=\"one\"", with: "VALUE=\"two\"")).fingerprint)
        XCTAssertNotEqual(try parse(base).fingerprint, try parse(base.replacingOccurrences(of: "skd://key-one", with: "skd://key-two")).fingerprint)
    }
    func testSidecarSubtitleSelectionDoesNotRequireStrippingIntrinsicCaptions() throws {
        let manifest = try parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CLOSED-CAPTIONS=\"cc\",SUBTITLES=\"sub\"\nvideo.m3u8\n#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"English\",LANGUAGE=\"en\",INSTREAM-ID=\"CC1\"\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"sub\",NAME=\"English\",LANGUAGE=\"en\",URI=\"en.m3u8\"\n")
        let video = manifest.tracks[0], subtitle = manifest.tracks[2]
        let selected = try manifest.select(["tracks": .object(["video": .array([.string(video.id)]), "text": .array([.string(subtitle.id)])])])
        XCTAssertEqual(selected.map(\.id), [video.id, subtitle.id])
        let withoutSidecars = try manifest.select(["tracks": .object(["text": .array([])])])
        XCTAssertEqual(withoutSidecars.map(\.id), [video.id])
        XCTAssertTrue(manifest.tracks[1].intrinsicCaptions)
    }
}
