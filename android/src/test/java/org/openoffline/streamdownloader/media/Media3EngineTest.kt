package org.openoffline.streamdownloader.media

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import com.brentvatne.common.api.Source
import java.io.IOException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.openoffline.streamdownloader.core.*
import org.openoffline.streamdownloader.storage.SQLiteStore
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class Media3EngineTest {
    private class FixtureSource(val resources: Map<String, ByteArray>) : DataSource.Factory {
        val requests: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val requestURIs: MutableList<String> = Collections.synchronizedList(mutableListOf())
        override fun createDataSource(): DataSource = object : DataSource {
            private var current: Uri? = null
            private var bytes = byteArrayOf()
            private var position = 0
            private var end = 0
            override fun open(spec: DataSpec): Long {
                current = spec.uri; val path = spec.uri.path!!; requests.add(path); requestURIs.add(spec.uri.toString())
                bytes = resources[path] ?: throw IOException("Unexpected fixture request: $path")
                position = spec.position.toInt()
                if (position > bytes.size) throw IOException("Out of range")
                end = if (spec.length < 0) bytes.size else minOf(bytes.size.toLong(), spec.position + spec.length).toInt()
                return (end - position).toLong()
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (position == end) return -1
                val count = minOf(719, length, end - position)
                bytes.copyInto(buffer, offset, position, position + count); position += count; return count
            }
            override fun getUri(): Uri? = current
            override fun addTransferListener(listener: TransferListener) = Unit
            override fun close() = Unit
        }
    }
    private fun fixture(path: String): ByteArray = javaClass.classLoader!!.getResourceAsStream("media/$path")!!.use { it.readBytes() }
    private fun record(url: String, options: Map<String, Any?> = emptyMap()) = Record(UUID.randomUUID().toString(), url, options, "fixture", 1)
    private fun complete(engine: Media3Engine, record: Record): Record {
        val result = CompletableFuture<TransferResult>()
        engine.start(record, {}, result::complete)
        val outcome = result.get(30, TimeUnit.SECONDS)
        assertTrue("Expected completion, got $outcome", outcome is TransferResult.Complete)
        val success = outcome as TransferResult.Complete
        return record.copy(asset = success.asset, state = State.COMPLETED, progress = 1.0)
    }

    @Test fun hlsDownloadsOnlySelectedVariantAndPersistsCacheOnlyPlaybackPlan() {
        val master = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=160x90,CODECS="avc1.640009,mp4a.40.2"
            low/media.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2"
            high/media.m3u8
        """.trimIndent().toByteArray()
        val source = FixtureSource(mapOf("/master" to master, "/low/media.m3u8" to fixture("hls/media.m3u8"),
            "/low/segment0.ts" to fixture("hls/segment0.ts"), "/low/segment1.ts" to fixture("hls/segment1.ts")))
        val catalog = MediaCatalog(source).inspect("https://fixture.test/master")
        val selected = catalog.tracks.first { it.type == "video" }
        val routes = OfflineRoutes(); val context = RuntimeEnvironment.getApplication()
        var engine = Media3Engine(context, routes, source)
        val store = SQLiteStore(context, routes::committed)
        try {
            val done = complete(engine, record(catalog.url, mapOf("tracks" to mapOf("video" to listOf(selected.id),
                "audio" to catalog.tracks.filter { it.type == "audio" }.map { it.id }, "text" to emptyList<String>()))))
            assertEquals(2000L, done.asset!!.duration)
            assertTrue(source.requests.contains("/low/segment0.ts")); assertTrue(source.requests.contains("/low/segment1.ts"))
            assertFalse(source.requests.any { it.startsWith("/high/") })
            assertTrue(engine.valid(done)); store.put(done)
            val reopened = store.load().single { it.id == done.id }
            assertEquals(done.asset, reopened.asset)
            engine.close()
            val forbiddenNetwork = FixtureSource(emptyMap())
            engine = Media3Engine(context, routes, forbiddenNetwork)
            assertTrue(engine.valid(reopened))
            val plugin = OfflineVideoPlugin(routes, engine)
            val playerSource = Source().apply { uri = Uri.parse(done.asset!!.path) }
            val item = plugin.overrideMediaItemBuilder(playerSource, MediaItem.Builder())!!.build()
            assertEquals(listOf(androidx.media3.common.StreamKey(0, 0, 0)), item.localConfiguration!!.streamKeys)
            assertEquals(catalog.url, item.localConfiguration!!.uri.toString())
            val cached = plugin.overrideMediaDataSourceFactory(playerSource, forbiddenNetwork)!!.createDataSource()
            cached.open(DataSpec(Uri.parse("https://fixture.test/low/segment0.ts")))
            try {
                val buffer = ByteArray(32); assertEquals(32, cached.read(buffer, 0, buffer.size))
                try { engine.delete(reopened); fail("Expected playback lease protection") }
                catch (error: DownloadFailure) { assertEquals("E_ASSET_IN_USE", error.code) }
            } finally { cached.close() }
            assertTrue(forbiddenNetwork.requests.isEmpty())
            engine.delete(reopened); assertFalse(engine.valid(reopened)); assertNull(routes.get(playerSource.uri))
        } finally { engine.close(); store.close() }
    }

    @Test fun hlsKeepsTrackSelectionsWhenMuxTransportSignaturesRotateAndFetchesTheNewURI() {
        val rendition = "https://manifest-gcp-us-east1-vop1.fastly.mux.com/opaque/rendition.m3u8?cdn=fastly&expires=100&skid=default&signature=first"
        val master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=160x90,CODECS=\"avc1.640009,mp4a.40.2\"\n$rendition\n"
        val resources = mutableMapOf("/master" to master.toByteArray(), "/opaque/rendition.m3u8" to fixture("hls/media.m3u8"),
            "/opaque/segment0.ts" to fixture("hls/segment0.ts"), "/opaque/segment1.ts" to fixture("hls/segment1.ts"))
        val source = FixtureSource(resources)
        val inspected = MediaCatalog(source).inspect("https://fixture.test/master")
        resources["/master"] = master.replace("expires=100", "expires=200").replace("signature=first", "signature=second").toByteArray()
        val engine = Media3Engine(RuntimeEnvironment.getApplication(), OfflineRoutes(), source)
        try {
            val options = mapOf("tracks" to inspected.tracks.groupBy { it.type }.mapValues { (_, tracks) -> tracks.map { it.id } })
            val done = complete(engine, record(inspected.url, options))
            assertEquals(2000L, done.asset!!.duration)
            assertTrue(source.requestURIs.any { it.contains("/rendition.m3u8?") && it.contains("signature=second") && it.contains("expires=200") })
            assertFalse(source.requestURIs.any { it.contains("signature=first") })
            assertTrue(engine.valid(done))
            engine.delete(done)
        } finally { engine.close() }
    }

    @Test fun intrinsicCaptionsDoNotPreventExcludingOrSelectingIndependentWebVTTResources() {
        val master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="Embedded English",LANGUAGE="en",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="en/subtitles.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Mongolian",LANGUAGE="mn",URI="mn/subtitles.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=160x90,CODECS="avc1.640009,mp4a.40.2",CLOSED-CAPTIONS="cc",SUBTITLES="subs"
            video/media.m3u8
        """.trimIndent().toByteArray()
        val source = FixtureSource(mapOf("/master" to master, "/video/media.m3u8" to fixture("hls/media.m3u8"),
            "/video/segment0.ts" to fixture("hls/segment0.ts"), "/video/segment1.ts" to fixture("hls/segment1.ts"),
            "/mn/subtitles.m3u8" to "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsubtitles.vtt\n#EXT-X-ENDLIST\n".toByteArray(),
            "/mn/subtitles.vtt" to "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nСайн байна уу\n".toByteArray()))
        val catalog = MediaCatalog(source).inspect("https://fixture.test/master")
        assertEquals(1, catalog.tracks.count { it.intrinsicCaption })
        val mongolian = catalog.tracks.single { it.type == "text" && it.dto["language"] == "mn" }
        val engine = Media3Engine(RuntimeEnvironment.getApplication(), OfflineRoutes(), source)
        try {
            for (text in listOf(emptyList(), listOf(mongolian.id))) {
                source.requests.clear()
                val done = complete(engine, record(catalog.url, mapOf("tracks" to mapOf("text" to text))))
                assertEquals(2000L, done.asset!!.duration)
                assertTrue(source.requests.contains("/video/segment0.ts"))
                assertFalse(source.requests.any { it.startsWith("/en/") })
                assertEquals(text.isNotEmpty(), source.requests.contains("/mn/subtitles.vtt"))
                assertTrue(engine.valid(done))
                engine.delete(done)
            }
        } finally { engine.close() }
    }

    @Test fun dashExcludesAudioSegmentsAndFailsClosedForMissingCachedBytes() {
        val source = FixtureSource(mapOf("/manifest" to fixture("dash/manifest.mpd"),
            "/init-stream0.m4s" to fixture("dash/init-stream0.m4s"),
            "/chunk-stream0-00001.m4s" to fixture("dash/chunk-stream0-00001.m4s"),
            "/chunk-stream0-00002.m4s" to fixture("dash/chunk-stream0-00002.m4s")))
        val context = RuntimeEnvironment.getApplication(); val routes = OfflineRoutes()
        val engine = Media3Engine(context, routes, source)
        try {
            val done = complete(engine, record("https://fixture.test/manifest", mapOf("tracks" to mapOf("audio" to emptyList<String>()))))
            assertEquals(2000L, done.asset!!.duration); assertTrue(engine.valid(done))
            assertFalse(source.requests.any { it.contains("stream1") })
            val count = source.requests.size
            val offline = engine.factory(done.id, false).createDataSource()
            try { offline.open(DataSpec(Uri.parse("https://fixture.test/missing.m4s"))); fail("A missing resource must fail offline") }
            catch (_: IOException) { /* Cache has no upstream factory. */ }
            finally { offline.close() }
            assertEquals(count, source.requests.size)
            engine.delete(done); assertFalse(engine.valid(done))
        } finally { engine.close() }
    }

    @Test fun rejectsEmbeddedTrackRemovalBeforeSegmentsAreTransferred() {
        val source = FixtureSource(mapOf("/master" to "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS=\"avc1.640009,mp4a.40.2\"\nmedia.m3u8\n".toByteArray()))
        val engine = Media3Engine(RuntimeEnvironment.getApplication(), OfflineRoutes(), source)
        try {
            val result = CompletableFuture<TransferResult>()
            engine.start(record("https://fixture.test/master", mapOf("tracks" to mapOf("audio" to emptyList<String>()))), {}, result::complete)
            val failure = result.get(10, TimeUnit.SECONDS) as TransferResult.Failed
            assertEquals("E_UNSUPPORTED_CAPABILITY", failure.error.code)
            assertTrue(source.requests.all { it == "/master" })
        } finally { engine.close() }
    }

    @Test fun singleHlsPlaylistReportsActualDemuxedVideoAndAudio() {
        val source = FixtureSource(mapOf("/media.m3u8" to fixture("hls/media.m3u8"),
            "/segment0.ts" to fixture("hls/segment0.ts"), "/segment1.ts" to fixture("hls/segment1.ts")))
        val catalog = MediaCatalog(source).inspect("https://fixture.test/media.m3u8")
        assertEquals(1, catalog.tracks.count { it.type == "video" })
        assertEquals(1, catalog.tracks.count { it.type == "audio" })
        assertEquals(mapOf("width" to 160, "height" to 90), catalog.tracks.first { it.type == "video" }.dto["resolution"])
        try { catalog.select(mapOf("tracks" to mapOf("audio" to emptyList<String>()))); fail("Cannot discard shared in-band audio") }
        catch (error: DownloadFailure) { assertEquals("E_UNSUPPORTED_CAPABILITY", error.code) }
    }
}
