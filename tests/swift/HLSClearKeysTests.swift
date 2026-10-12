import XCTest
@testable import StreamDownloaderCore

final class HLSClearKeysTests: XCTestCase {
    let media = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=AES-128,URI="streamdl-key://cdn.example/api/hls/key/9d87?cdn_token=abc&expires=1",IV=0x0123456789abcdef0123456789abcdef
    #EXTINF:6.0,
    segment_000.ts
    #EXT-X-KEY:METHOD=AES-128,URI="streamdl-key://cdn.example/api/hls/key/9d87?cdn_token=def&expires=2"
    #EXTINF:6.0,
    segment_001.ts
    #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/api/hls/key/other"
    #EXTINF:6.0,
    segment_002.ts
    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay",KEYFORMAT="com.apple.streamingkeydelivery"
    #EXT-X-KEY:METHOD=NONE
    #EXT-X-ENDLIST
    """

    func testCollectsOnlyPackageSchemeAES128Keys() throws {
        let uris = try HLSClearKeys.keyURIs(Data(media.utf8))
        XCTAssertEqual(uris, [
            "streamdl-key://cdn.example/api/hls/key/9d87?cdn_token=abc&expires=1",
            "streamdl-key://cdn.example/api/hls/key/9d87?cdn_token=def&expires=2",
        ])
        // The playlist still parses as clear (non-DRM) media.
        let manifest = try HLSManifest(data: Data(media.utf8), baseURL: URL(string: "https://cdn.example/v/720p/index.m3u8")!)
        XCTAssertFalse(manifest.isMaster)
    }

    func testFetchURLSwapsOnlyTheScheme() {
        XCTAssertEqual(HLSClearKeys.fetchURL("streamdl-key://cdn.example:8443/api/hls/key/9d87?cdn_token=a&expires=1")?.absoluteString,
                       "https://cdn.example:8443/api/hls/key/9d87?cdn_token=a&expires=1")
        XCTAssertNil(HLSClearKeys.fetchURL("https://cdn.example/key"))
        XCTAssertNil(HLSClearKeys.fetchURL("streamdl-key:///no-host"))
        XCTAssertNil(HLSClearKeys.fetchURL("streamdl-key://user:pass@cdn.example/key"))
        XCTAssertTrue(HLSClearKeys.isClearKeyURI("STREAMDL-KEY://cdn.example/key"))
    }

    func testIdentityIgnoresRenewableQuery() {
        let first = HLSClearKeys.identity("streamdl-key://CDN.example/api/hls/key/9d87?cdn_token=abc&expires=1")
        let renewed = HLSClearKeys.identity("streamdl-key://cdn.example/api/hls/key/9d87?cdn_token=xyz&expires=9")
        XCTAssertEqual(first, "cdn.example/api/hls/key/9d87")
        XCTAssertEqual(first, renewed)
        XCTAssertNotEqual(first, HLSClearKeys.identity("streamdl-key://cdn.example/api/hls/key/other"))
    }

    func testRejectsMalformedKeysAndURIs() {
        XCTAssertTrue(HLSClearKeys.isValidKey(Data(count: 16)))
        XCTAssertFalse(HLSClearKeys.isValidKey(Data(count: 15)))
        XCTAssertFalse(HLSClearKeys.isValidKey(Data("{\"status\":false,\"code\":401}".utf8)))
        let broken = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"streamdl-key:///missing-host\"\n"
        XCTAssertThrowsError(try HLSClearKeys.keyURIs(Data(broken.utf8)))
    }
}
