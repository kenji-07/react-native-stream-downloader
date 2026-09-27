package org.openoffline.streamdownloader.media

import android.net.Uri
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.StreamKey
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.nio.charset.StandardCharsets
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.openoffline.streamdownloader.core.DownloadFailure
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class MediaCatalogTest {
    private val master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English, stereo",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="en/list.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Mongolian",LANGUAGE="mn",DEFAULT=NO,AUTOSELECT=YES,URI="mn/list.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English captions",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="sub/list.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
        low/list.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
        high/list.m3u8
    """.trimIndent()

    private fun catalog(text: String, finalURL: String = "https://media.test/final/master.m3u8", mediaFormats: List<Format>? = null): MediaCatalog.Catalog {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        val factory = DataSource.Factory { object : DataSource {
            private var position = 0
            override fun open(spec: DataSpec): Long { position = 0; return bytes.size.toLong() }
            override fun getUri(): Uri = Uri.parse(finalURL)
            override fun addTransferListener(listener: TransferListener) = Unit
            override fun close() = Unit
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (position == bytes.size) return -1
                // Three-byte chunks catch incorrect assumptions about HTTP read sizes.
                val count = minOf(3, length, bytes.size - position)
                bytes.copyInto(buffer, offset, position, position + count); position += count; return count
            }
        } }
        val inspector = if (mediaFormats == null) MediaCatalog(factory) else MediaCatalog(factory) { _, _ -> mediaFormats }
        return inspector.inspect("https://media.test/redirect")
    }

    @Test fun parsesQuotedAttributesRelativeURIsAndActualSelectionKeys() {
        val catalog = catalog(master)
        assertEquals(2, catalog.tracks.count { it.type == "video" }); assertEquals(2, catalog.tracks.count { it.type == "audio" })
        val english = catalog.tracks.first { it.type == "audio" }
        assertEquals("English, stereo", english.dto["name"])
        assertEquals("https://media.test/final/en/list.m3u8", english.dto["uri"])
        val video = catalog.tracks.first { it.type == "video" }
        val mongolian = catalog.tracks.last { it.type == "audio" }
        val selected = catalog.select(mapOf("includeAllTracks" to true, "tracks" to mapOf("video" to listOf(video.id), "audio" to listOf(mongolian.id), "text" to emptyList<String>())))
        assertEquals(listOf(StreamKey(0, 0, 0), StreamKey(0, 1, 1)), selected.mapNotNull { it.key })
        assertEquals(listOf(video.id, mongolian.id), selected.map { it.id })
    }

    @Test fun missingSelectionsRetainAllCompatibleRenditions() {
        val catalog = catalog(master)
        assertEquals(catalog.tracks, catalog.select(emptyMap()))
        val low = catalog.tracks.first { it.type == "video" }
        val selected = catalog.select(mapOf("tracks" to mapOf("video" to listOf(low.id))))
        assertEquals(4, selected.size); assertEquals(2, selected.count { it.type == "audio" })
    }

    @Test fun rejectsUnknownAndStaleTrackIDs() {
        val original = catalog(master)
        val changed = catalog(master.replace("800000", "810000"))
        try { changed.select(mapOf("tracks" to mapOf("video" to listOf(original.tracks.first().id)))); fail("Expected stale ID rejection") }
        catch (error: DownloadFailure) { assertEquals("E_INVALID_TRACKS", error.code) }
    }

    @Test fun selectingAllEmbeddedAudioIDsKeepsOnlyTheChosenVariantsAudio() {
        val parsed = catalog("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
            low/list.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
            high/list.m3u8
        """.trimIndent())
        val videos = parsed.tracks.filter { it.type == "video" }
        val audio = parsed.tracks.filter { it.type == "audio" }
        val chosen = parsed.select(mapOf("tracks" to mapOf("video" to listOf(videos.first().id), "audio" to audio.map { it.id }, "text" to emptyList<String>())))
        assertEquals(listOf(videos.first().id, audio.first().id), chosen.map { it.id })
        assertEquals(listOf(StreamKey(0, 0, 0)), chosen.mapNotNull { it.key })
        try {
            parsed.select(mapOf("tracks" to mapOf("video" to listOf(videos.first().id), "audio" to listOf(audio.last().id))))
            fail("An explicit incompatible subset must still fail")
        } catch (error: DownloadFailure) { assertEquals("E_INVALID_TRACKS", error.code) }
        try {
            parsed.select(mapOf("tracks" to mapOf("video" to listOf(videos.first().id), "audio" to emptyList<String>())))
            fail("Embedded audio cannot be physically excluded")
        } catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_CAPABILITY", error.code) }
    }

    @Test fun completeExternalAudioAndTextSelectionsResolveToCompatibleGroups() {
        val parsed = catalog("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="low-a",NAME="English",URI="low/audio.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="high-a",NAME="English",URI="high/audio.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="low-t",NAME="English",URI="low/text.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="high-t",NAME="English",URI="high/text.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="low-a",SUBTITLES="low-t"
            low/list.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="high-a",SUBTITLES="high-t"
            high/list.m3u8
        """.trimIndent())
        val low = parsed.tracks.first { it.type == "video" }
        val audio = parsed.tracks.filter { it.type == "audio" }
        val text = parsed.tracks.filter { it.type == "text" }
        val chosen = parsed.select(mapOf("tracks" to mapOf("video" to listOf(low.id), "audio" to audio.map { it.id }, "text" to text.map { it.id })))
        assertEquals(listOf(low.id, audio.first().id, text.first().id), chosen.map { it.id })
        try {
            parsed.select(mapOf("tracks" to mapOf("video" to listOf(low.id), "text" to listOf(text.last().id))))
            fail("An explicit incompatible subtitle group must still fail")
        } catch (error: DownloadFailure) { assertEquals("E_INVALID_TRACKS", error.code) }
    }

    @Test fun mediaPlaylistRetainsIntrinsicCaptionsWithoutPermittingEmbeddedAudioRemoval() {
        val playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val formats = listOf(MimeTypes.VIDEO_H264, MimeTypes.AUDIO_AAC, MimeTypes.APPLICATION_CEA608, MimeTypes.APPLICATION_CEA708)
            .map { Format.Builder().setSampleMimeType(it).build() }
        val parsed = catalog(playlist, mediaFormats = formats)
        assertEquals(2, parsed.tracks.count { it.intrinsicCaption })
        val selected = parsed.select(mapOf("tracks" to mapOf("text" to emptyList<String>())))
        assertEquals(listOf("video", "audio"), selected.map { it.type })
        try {
            parsed.select(mapOf("tracks" to mapOf("audio" to emptyList<String>(), "text" to emptyList<String>())))
            fail("Embedded audio removal must still require remuxing")
        } catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_CAPABILITY", error.code) }
        val otherEmbeddedText = catalog(playlist, mediaFormats = formats.take(2) + Format.Builder().setSampleMimeType(MimeTypes.TEXT_VTT).build())
        try {
            otherEmbeddedText.select(mapOf("tracks" to mapOf("text" to emptyList<String>())))
            fail("Only intrinsic CEA captions receive the retention exception")
        } catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_CAPABILITY", error.code) }
    }

    @Test fun trackIdentityIgnoresSessionMetadataAndCommentsButKeepsPlaybackChanges() {
        val original = catalog(master)
        val decorated = catalog((master + "\n# A response-specific comment\n#EXT-X-SESSION-DATA:DATA-ID=\"com.mux.session-id\",VALUE=\"new-session\"\n").replace("\n", "\r\n"))
        assertEquals(original.fingerprint, decorated.fingerprint)
        assertEquals(original.tracks.map { it.id }, decorated.tracks.map { it.id })
        assertNotEquals(original.fingerprint, catalog(master.replace("avc1.4d401e", "avc1.4d401f")).fingerprint)
        assertNotEquals(original.fingerprint, catalog(master.replace("low/list.m3u8", "low/list.m3u8?token=new")).fingerprint)
        val key = "\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"https://media.test/key?token=one\"\n"
        assertNotEquals(catalog(master + key).fingerprint, catalog(master + key.replace("token=one", "token=two")).fingerprint)
    }

    @Test fun muxRenditionTransportSignaturesDoNotInvalidateTrackIDs() {
        val rendition = "https://manifest-gcp-us-east1-vop1.fastly.mux.com/opaque/rendition.m3u8?cdn=fastly&expires=100&skid=default&signature=first"
        val original = master.replace("low/list.m3u8", rendition).replace("en/list.m3u8", rendition.replace("/opaque/", "/audio/"))
        val rotated = original.replace("expires=100", "expires=200").replace("signature=first", "signature=second")
        val before = catalog(original)
        val after = catalog(rotated)
        assertEquals(before.fingerprint, after.fingerprint)
        assertEquals(before.tracks.map { it.id }, after.tracks.map { it.id })
        assertTrue((after.tracks.first().dto["uri"] as String).contains("signature=second"))
        assertNotEquals(before.fingerprint, catalog(rotated.replace("/opaque/", "/different/")).fingerprint)
        assertNotEquals(before.fingerprint, catalog(rotated.replace("skid=default", "skid=other")).fingerprint)
        for (uri in listOf(
            rendition.replace("fastly.mux.com", "fastly.example.com"),
            rendition.replace("https://", "http://"),
            rendition.replace("/rendition.m3u8", "/key.bin"),
            rendition.replace("&expires=100", ""),
        )) {
            val first = master.replace("low/list.m3u8", uri)
            assertNotEquals(catalog(first).fingerprint, catalog(first.replace("signature=first", "signature=second")).fingerprint)
        }
        // Even on the provider's rendition host, encryption declarations retain
        // their complete credential-bearing URI as part of media identity.
        val key = "\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"$rendition\"\n"
        assertNotEquals(catalog(master + key).fingerprint, catalog(master + key.replace("signature=first", "signature=second")).fingerprint)
    }

    @Test fun rejectsLivePlaylistsAndMalformedMedia() {
        try { catalog("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n"); fail("Expected finite VOD requirement") }
        catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_MEDIA", error.code) }
        try { catalog("not a media stream"); fail("Expected format rejection") }
        catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_MEDIA", error.code) }
    }

    @Test fun rejectsUnrecognizedSampleEncryptionBeforeTreatingItAsClearMedia() {
        for (key in listOf(
            "METHOD=SAMPLE-AES,URI=\"skd://asset\",KEYFORMAT=\"com.apple.streamingkeydelivery\"",
            "METHOD=SAMPLE-AES,URI=\"https://media.test/key\"",
            "METHOD=AES-128,URI=\"https://media.test/key\",KEYFORMAT=\"unknown.provider\"",
        )) {
            val playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:$key\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
            try { catalog(playlist); fail("Unsupported encryption must not become a clear download") }
            catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_CAPABILITY", error.code) }
        }
    }

    @Test fun dashSelectionRetainsPeriodsAndMapsRepresentations() {
        val manifest = """
          <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" minBufferTime="PT1S">
            <Period id="p0" start="PT0S" duration="PT10S">
              <AdaptationSet id="10" contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">
                <SegmentTemplate timescale="1" duration="2" media="v/${'$'}RepresentationID${'$'}/${'$'}Number${'$'}.m4s" initialization="v/init.mp4"/>
                <Representation id="low" bandwidth="800000" width="640" height="360"/>
                <Representation id="high" bandwidth="2400000" width="1280" height="720"/>
              </AdaptationSet>
            </Period>
            <Period id="p1" start="PT10S" duration="PT10S">
              <AdaptationSet id="20" contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">
                <SegmentTemplate timescale="1" duration="2" media="v2/${'$'}Number${'$'}.m4s" initialization="v2/init.mp4"/>
                <Representation id="second" bandwidth="800000" width="640" height="360"/>
              </AdaptationSet>
            </Period>
          </MPD>
        """.trimIndent()
        val parsed = catalog(manifest, "https://media.test/movie/manifest.mpd")
        assertEquals("dash", parsed.kind); assertEquals(3, parsed.tracks.size); assertEquals(20000L, parsed.duration)
        val selected = parsed.select(mapOf("tracks" to mapOf("video" to listOf(parsed.tracks[0].id, parsed.tracks[2].id))))
        assertEquals(listOf(StreamKey(0, 0, 0), StreamKey(1, 0, 0)), selected.map { it.key })
        try { parsed.select(mapOf("tracks" to mapOf("video" to listOf(parsed.tracks[0].id)))); fail("Expected period retention requirement") }
        catch (error: DownloadFailure) { assertEquals("E_INVALID_TRACKS", error.code) }
    }
}
