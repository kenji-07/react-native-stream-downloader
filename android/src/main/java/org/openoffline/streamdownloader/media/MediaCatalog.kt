package org.openoffline.streamdownloader.media

import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.StreamKey
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.UriUtil
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.dash.manifest.DashManifest
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParser
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import org.openoffline.streamdownloader.core.DownloadFailure

@UnstableApi
internal class MediaCatalog(
    private val factory: DataSource.Factory,
    private val hlsProbe: (String, DataSource.Factory) -> List<Format> = NativeTrackProbe::hls,
) {
    data class Track(val type: String, val dto: Map<String, Any?>, val key: StreamKey?, val embedded: Boolean = false, val format: Format? = null, val linkedVariant: Int? = null) {
        val id: String get() = dto.getValue("id") as String
        val intrinsicCaption: Boolean get() = embedded && type == "text" &&
            format?.sampleMimeType in listOf(MimeTypes.APPLICATION_CEA608, MimeTypes.APPLICATION_CEA708)
    }
    data class Catalog(val kind: String, val url: String, val fingerprint: String, val tracks: List<Track>, val hls: HlsPlaylist? = null, val dash: DashManifest? = null, val duration: Long = 0, val encrypted: Boolean = false) {
        fun publicTracks(): Map<String, Any?> = listOf("video", "audio", "text").associateWith { type -> tracks.filter { it.type == type }.map { it.dto } }
        fun select(options: Map<String, Any?>): List<Track> {
            val requested = options["tracks"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val selected = tracks.filter { track ->
                val ids = requested[track.type] as? List<*> ?: return@filter true
                track.id in ids
            }
            for ((type, ids) in requested) {
                if ((ids as List<*>).any { id -> tracks.none { it.type == type && it.id == id } }) {
                    throw DownloadFailure("E_INVALID_TRACKS", "A selected track is unknown or belongs to a changed manifest.")
                }
            }
            if (selected.isEmpty()) throw DownloadFailure("E_INVALID_TRACKS", "The selection contains no downloadable tracks.")
            if (hls is HlsMediaPlaylist && tracks.any { it !in selected && !it.intrinsicCaption }) {
                throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Tracks sharing an HLS media playlist cannot be removed without remuxing its segments.")
            }
            if (hls is HlsMultivariantPlaylist) {
                // A caller may forward every ID returned by getAvailableTracks
                // while choosing one video quality. Treat that complete category
                // as "all compatible", just like an omitted category. A smaller
                // explicit selection must still belong to the chosen variants.
                val allCategories = requested.filter { (type, ids) ->
                    (ids as List<*>).toSet() == tracks.filter { it.type == type }.map { it.id }.toSet()
                }.keys
                val variants = selected.filter { it.key?.groupIndex == HlsMultivariantPlaylist.GROUP_INDEX_VARIANT }
                val variantIndices = variants.map { it.key!!.streamIndex }.toSet()
                val audioGroups = variants.mapNotNull { hls.variants[it.key!!.streamIndex].audioGroupId }.toSet()
                val textGroups = variants.mapNotNull { hls.variants[it.key!!.streamIndex].subtitleGroupId }.toSet()
                val compatible = selected.filter { track -> when {
                    track.linkedVariant != null -> track.linkedVariant in variantIndices
                    track.embedded || track.key?.groupIndex == HlsMultivariantPlaylist.GROUP_INDEX_VARIANT || variants.isEmpty() -> true
                    track.type == "audio" -> track.dto["groupId"] in audioGroups
                    track.type == "text" -> track.dto["groupId"] in textGroups
                    else -> false
                } }
                if (selected.any { it !in compatible && requested.containsKey(it.type) && it.type !in allCategories }) throw DownloadFailure("E_INVALID_TRACKS", "The chosen HLS renditions do not belong to the selected variant groups.")
                // CEA-608/708 data is intrinsic to the selected video segments.
                // Selecting sidecar subtitles (or none) retains those bytes;
                // it must not prevent filtering independent WebVTT resources.
                // Embedded audio and other embedded text still cannot be removed.
                if (tracks.any { it.embedded && !it.intrinsicCaption && it !in selected && (it.linkedVariant == null || it.linkedVariant in variantIndices) } && variants.isNotEmpty()) {
                    throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "In-band HLS tracks cannot be removed independently from their shared segments.")
                }
                return compatible
            }
            if (dash != null) {
                // Removing a whole period would collapse the presentation timeline.
                for (period in 0 until dash.periodCount) {
                    if (selected.none { it.key?.periodIndex == period && it.type != "text" }) throw DownloadFailure("E_INVALID_TRACKS", "Each DASH period must retain an audio or video representation.")
                }
            }
            return selected
        }
    }

    fun inspect(url: String): Catalog {
        val (bytes, baseUrl) = manifestBytes(url)
        val text = bytes.toString(Charsets.UTF_8).trimStart('\uFEFF', ' ', '\r', '\n', '\t')
        return when {
            text.startsWith("#EXTM3U") -> hls(url, bytes, baseUrl)
            text.startsWith("<") -> dash(url, bytes, baseUrl)
            bytes.size >= 8 && bytes.copyOfRange(4, 8).toString(Charsets.US_ASCII) in listOf("ftyp", "moov", "mdat", "free", "wide") -> mp4(url)
            else -> throw DownloadFailure("E_UNSUPPORTED_MEDIA", "The response is not a supported HLS, DASH or MP4 resource.")
        }
    }

    private fun manifestBytes(url: String): Pair<ByteArray, String> {
        val source = factory.createDataSource()
        try {
            source.open(DataSpec(Uri.parse(url)))
            val first = ByteArray(1024)
            var count = 0
            while (count < first.size) {
                val read = source.read(first, count, first.size - count)
                if (read < 0) break
                count += read
            }
            if (count <= 0) throw DownloadFailure("E_INVALID_STREAM", "The media response is empty.")
            val prefix = first.copyOf(count).toString(Charsets.UTF_8).trimStart('\uFEFF', ' ', '\r', '\n', '\t')
            val baseUrl = source.uri?.toString() ?: url
            if (!prefix.startsWith("#EXTM3U") && !prefix.startsWith("<")) return first.copyOf(count) to baseUrl
            val output = ByteArrayOutputStream(); output.write(first, 0, count)
            val buffer = ByteArray(16384)
            while (true) {
                val read = source.read(buffer, 0, buffer.size)
                if (read < 0) break
                if (output.size() + read > 8 * 1024 * 1024) throw DownloadFailure("E_MANIFEST", "The manifest exceeds the supported 8 MiB size.")
                output.write(buffer, 0, read)
            }
            return output.toByteArray() to baseUrl
        } finally { source.close() }
    }

    private fun hls(url: String, bytes: ByteArray, baseUrl: String): Catalog {
        validateEncryptionSignaling(bytes)
        val playlist = HlsPlaylistParser().parse(Uri.parse(baseUrl), ByteArrayInputStream(bytes))
        val fingerprint = hlsFingerprint(baseUrl, bytes)
        val tracks = mutableListOf<Track>()
        if (playlist is HlsMultivariantPlaylist) {
            playlist.variants.forEachIndexed { index, variant ->
                val id = "$fingerprint:v:$index"
                val audioMime = MimeTypes.getAudioMediaMimeType(variant.format.codecs)
                val audioOnly = audioMime != null && MimeTypes.getVideoMediaMimeType(variant.format.codecs) == null && variant.format.height <= 0
                val type = if (audioOnly) "audio" else "video"
                val dto = if (audioOnly) renditionDTO(id, type, variant.url.toString(), "variant", variant.format.label ?: "Audio $index", variant.format)
                    else video(id, variant.url.toString(), variant.format)
                tracks.add(Track(type, dto + optional(mapOf(
                    "audioGroupId" to variant.audioGroupId, "subtitlesGroupId" to variant.subtitleGroupId,
                    "captionGroupId" to variant.captionGroupId, "videoGroupId" to variant.videoGroupId,
                )), StreamKey(0, HlsMultivariantPlaylist.GROUP_INDEX_VARIANT, index), format = variant.format))
                if (!audioOnly && audioMime != null && variant.audioGroupId == null && playlist.muxedAudioFormat == null) {
                    tracks.add(Track("audio", renditionDTO("$fingerprint:inband:$index", "audio", variant.url.toString(), "inband:$index", "Embedded audio", variant.format),
                        null, true, variant.format, index))
                }
            }
            playlist.audios.forEachIndexed { index, rendition ->
                tracks.add(Track("audio", renditionDTO("$fingerprint:a:$index", "audio", rendition.url?.toString() ?: url, rendition.groupId, rendition.name, rendition.format),
                    rendition.url?.let { StreamKey(0, HlsMultivariantPlaylist.GROUP_INDEX_AUDIO, index) }, rendition.url == null, rendition.format))
            }
            playlist.subtitles.forEachIndexed { index, rendition ->
                tracks.add(Track("text", renditionDTO("$fingerprint:t:$index", "text", rendition.url?.toString() ?: url, rendition.groupId, rendition.name, rendition.format),
                    rendition.url?.let { StreamKey(0, HlsMultivariantPlaylist.GROUP_INDEX_SUBTITLE, index) }, rendition.url == null, rendition.format))
            }
            playlist.muxedAudioFormat?.let { format ->
                tracks.add(Track("audio", renditionDTO("$fingerprint:embedded:audio", "audio", url, playlist.variants.firstOrNull()?.audioGroupId ?: "", format.label ?: "Audio", format), null, true, format))
            }
            playlist.muxedCaptionFormats?.forEachIndexed { index, format ->
                tracks.add(Track("text", renditionDTO("$fingerprint:embedded:text:$index", "text", url, playlist.variants.firstOrNull()?.captionGroupId ?: "", format.label ?: "Captions", format), null, true, format))
            }
        } else if (playlist is HlsMediaPlaylist) {
            if (!playlist.hasEndTag) throw DownloadFailure("E_UNSUPPORTED_MEDIA", "Only finite HLS VOD playlists support this offline download flow.")
            hlsProbe(url, factory).forEachIndexed { index, format ->
                val mime = format.sampleMimeType ?: return@forEachIndexed
                val type = when { MimeTypes.isVideo(mime) -> "video"; MimeTypes.isAudio(mime) -> "audio"; MimeTypes.isText(mime) -> "text"; else -> return@forEachIndexed }
                val id = "$fingerprint:media:$index"
                val dto = if (type == "video") video(id, url, format)
                    else renditionDTO(id, type, url, "media:$type", format.label ?: format.id ?: "$type $index", format)
                tracks.add(Track(type, dto, null, true, format))
            }
        }
        if (tracks.isEmpty()) throw DownloadFailure("E_INVALID_STREAM", "The HLS manifest has no downloadable renditions.")
        return Catalog("hls", url, fingerprint, tracks, hls = playlist, duration = (playlist as? HlsMediaPlaylist)?.durationUs?.div(1000) ?: 0)
    }

    data class AdaptiveInfo(val duration: Long, val drmFormats: List<Format>, val encrypted: Boolean)

    /** Check every selected child before transferring segments, including audio/text playlists. */
    fun validateAdaptive(catalog: Catalog, selected: List<Track>): Long {
        val info = adaptiveInfo(catalog, selected)
        if (info.encrypted) throw DownloadFailure("E_DRM_REQUIRED", "Encrypted media requires persistent license preparation.")
        return info.duration
    }

    fun adaptiveInfo(catalog: Catalog, selected: List<Track>): AdaptiveInfo {
        if (catalog.dash != null) {
            val formats = selected.mapNotNull { it.format }.filter { it.drmInitData != null }
            return AdaptiveInfo(catalog.duration, formats, formats.isNotEmpty())
        }
        val playlist = catalog.hls ?: return AdaptiveInfo(catalog.duration, emptyList(), catalog.encrypted)
        val media = if (playlist is HlsMediaPlaylist) listOf(playlist) else selected.mapNotNull { track ->
            if (track.key == null) null else track.dto["uri"] as String
        }.distinct().map { uri ->
            val (bytes, baseUrl) = manifestBytes(uri)
            validateEncryptionSignaling(bytes)
            val child = HlsPlaylistParser(playlist as HlsMultivariantPlaylist, null).parse(Uri.parse(baseUrl), ByteArrayInputStream(bytes))
            child as? HlsMediaPlaylist ?: throw DownloadFailure("E_MANIFEST", "A rendition must reference an HLS media playlist.")
        }
        if (media.isEmpty()) throw DownloadFailure("E_INVALID_STREAM", "No HLS media playlists were selected.")
        val formats = mutableListOf<Format>()
        media.forEach {
            if (!it.hasEndTag) throw DownloadFailure("E_UNSUPPORTED_MEDIA", "Only finite HLS VOD playlists support offline download.")
            it.segments.forEach { segment ->
                segment.drmInitData?.let { data ->
                    if (segment.initializationSegment == null) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Persistent DRM on Android requires fragmented MP4 HLS segments.")
                    formats.add(Format.Builder().setSampleMimeType(MimeTypes.VIDEO_MP4).setDrmInitData(data).build())
                }
            }
            if (it.protectionSchemes != null && it.segments.none { segment -> segment.drmInitData != null }) {
                formats.add(Format.Builder().setSampleMimeType(MimeTypes.VIDEO_MP4).setDrmInitData(it.protectionSchemes).build())
            }
        }
        return AdaptiveInfo(media.maxOf { it.durationUs / 1000 }, formats.distinct(), formats.isNotEmpty())
    }

    /** Media3 deliberately ignores unknown key formats; they must not become clear assets. */
    private fun validateEncryptionSignaling(bytes: ByteArray) {
        var sampleEncrypted = false
        var supportedSampleScheme = false
        val supportedFormats = setOf("urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed", "com.widevine", "com.microsoft.playready")
        for (line in bytes.toString(Charsets.UTF_8).lineSequence().map(String::trim)) {
            if (line.startsWith("#EXT-X-KEY:")) {
                val method = Regex("(?:^|,)METHOD=([^,]+)").find(line.substringAfter(':'))?.groupValues?.get(1)
                    ?: throw DownloadFailure("E_MANIFEST", "An HLS encryption declaration is missing its method.")
                val format = Regex("(?:^|,)KEYFORMAT=\"([^\"]+)\"").find(line.substringAfter(':'))?.groupValues?.get(1) ?: "identity"
                when {
                    method == "NONE" -> { sampleEncrypted = false; supportedSampleScheme = false }
                    method == "AES-128" && format == "identity" -> sampleEncrypted = false
                    method in setOf("SAMPLE-AES", "SAMPLE-AES-CENC", "SAMPLE-AES-CTR") -> {
                        sampleEncrypted = true
                        // Different KEYFORMAT declarations can provide equivalent
                        // keys together; one supported scheme is sufficient here.
                        if (format in supportedFormats) supportedSampleScheme = true
                    }
                    else -> throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "This HLS encryption method is not supported by the offline downloader.")
                }
            } else if (line.isNotEmpty() && !line.startsWith('#') && sampleEncrypted && !supportedSampleScheme) {
                throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "The HLS media has no supported Android persistent DRM key format.")
            }
        }
    }

    private fun dash(url: String, bytes: ByteArray, baseUrl: String): Catalog {
        val manifest = DashManifestParser().parse(Uri.parse(baseUrl), ByteArrayInputStream(bytes))
        if (manifest.dynamic) throw DownloadFailure("E_UNSUPPORTED_MEDIA", "Dynamic DASH manifests cannot be committed as finite offline assets.")
        val fingerprint = digest(baseUrl.toByteArray() + byteArrayOf(0) + bytes); val tracks = mutableListOf<Track>()
        for (period in 0 until manifest.periodCount) {
            manifest.getPeriod(period).adaptationSets.forEachIndexed { group, set ->
                val type = when (set.type) { C.TRACK_TYPE_VIDEO -> "video"; C.TRACK_TYPE_AUDIO -> "audio"; C.TRACK_TYPE_TEXT -> "text"; else -> return@forEachIndexed }
                set.representations.forEachIndexed { index, representation ->
                    val id = "$fingerprint:$period:$group:$index"
                    val uri = representation.baseUrls.firstOrNull()?.url ?: url
                    val format = representation.format
                    val dto = if (type == "video") video(id, uri, format)
                        else renditionDTO(id, type, uri, "$period:${set.id}", format.label ?: format.id ?: "$type $index", format)
                    tracks.add(Track(type, dto, StreamKey(period, group, index), format = format))
                }
            }
        }
        if (tracks.isEmpty()) throw DownloadFailure("E_INVALID_STREAM", "The DASH manifest has no downloadable representations.")
        return Catalog("dash", url, fingerprint, tracks, dash = manifest, duration = manifest.durationMs.coerceAtLeast(0))
    }

    private fun mp4(url: String): Catalog {
        val extractor = MediaExtractor()
        val source = ExtractorDataSource(factory, url)
        try {
            extractor.setDataSource(source)
            val rows = mutableListOf<Pair<Int, Map<String, Any?>>>()
            var duration = 0L
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val type = when { MimeTypes.isVideo(mime) -> "video"; MimeTypes.isAudio(mime) -> "audio"; MimeTypes.isText(mime) -> "text"; else -> continue }
                val data = mutableMapOf<String, Any?>("type" to type, "uri" to url)
                if (type == "video") {
                    data["bandwidth"] = if (format.containsKey(MediaFormat.KEY_BIT_RATE)) format.getInteger(MediaFormat.KEY_BIT_RATE) else 0
                    if (format.containsKey(MediaFormat.KEY_WIDTH) && format.containsKey(MediaFormat.KEY_HEIGHT)) data["resolution"] = mapOf("width" to format.getInteger(MediaFormat.KEY_WIDTH), "height" to format.getInteger(MediaFormat.KEY_HEIGHT))
                } else {
                    data["groupId"] = "mp4:$type"; data["name"] = "$type $index"
                    format.getString(MediaFormat.KEY_LANGUAGE)?.let { data["language"] = it }
                    if (format.containsKey(MediaFormat.KEY_IS_DEFAULT)) data["isDefault"] = format.getInteger(MediaFormat.KEY_IS_DEFAULT) != 0
                    if (format.containsKey(MediaFormat.KEY_IS_AUTOSELECT)) data["autoSelect"] = format.getInteger(MediaFormat.KEY_IS_AUTOSELECT) != 0
                    if (type == "text" && format.containsKey(MediaFormat.KEY_IS_FORCED_SUBTITLE)) data["forced"] = format.getInteger(MediaFormat.KEY_IS_FORCED_SUBTITLE) != 0
                }
                if (format.containsKey(MediaFormat.KEY_DURATION)) duration = maxOf(duration, format.getLong(MediaFormat.KEY_DURATION) / 1000)
                rows.add(index to data)
            }
            if (rows.isEmpty()) throw DownloadFailure("E_INVALID_STREAM", "The media contains no supported tracks.")
            val fingerprint = digest(org.openoffline.streamdownloader.storage.Json.encode(mapOf("tracks" to rows.map { it.second }, "duration" to duration)).toByteArray())
            return Catalog("mp4", url, fingerprint, rows.map { (index, row) -> Track(row["type"] as String, row + ("id" to "$fingerprint:mp4:$index"), StreamKey(0, 0, index), true) }, duration = duration, encrypted = !extractor.psshInfo.isNullOrEmpty())
        } finally { extractor.release(); source.close() }
    }

    private fun video(id: String, uri: String, format: Format): Map<String, Any?> = buildMap {
        put("id", id); put("type", "video"); put("uri", uri); put("bandwidth", maxOf(0, format.peakBitrate, format.averageBitrate))
        if (format.width > 0 && format.height > 0) put("resolution", mapOf("width" to format.width, "height" to format.height))
        format.codecs?.let { put("codecs", it) }; format.label?.let { put("label", it) }
    }
    private fun renditionDTO(id: String, type: String, uri: String, group: String, name: String, format: Format): Map<String, Any?> = buildMap {
        put("id", id); put("type", type); put("uri", uri); put("groupId", group); put("name", name)
        format.language?.let { put("language", it) }
        put("isDefault", format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0)
        put("autoSelect", format.selectionFlags and C.SELECTION_FLAG_AUTOSELECT != 0)
        if (type == "text") put("forced", format.selectionFlags and C.SELECTION_FLAG_FORCED != 0)
    }
    private fun optional(map: Map<String, Any?>): Map<String, Any?> = map.filterValues { it != null }
    private fun hlsFingerprint(baseUrl: String, bytes: ByteArray): String {
        // Session metadata (for example Mux's per-request session ID) is not a
        // track or media identity. Comments and line-ending differences likewise
        // do not change selection. Retain every other EXT tag, especially key
        // declarations. Only known Mux rendition transport signatures are omitted
        // from identity; HTTP requests and the public track URIs remain unchanged.
        val identity = bytes.toString(Charsets.UTF_8).trimStart('\uFEFF').lineSequence()
            .map(String::trim)
            .filter { it.isNotEmpty() && (!it.startsWith('#') || it.startsWith("#EXT")) }
            .filterNot { it.startsWith("#EXT-X-SESSION-DATA:") }
            .map { line -> when {
                !line.startsWith('#') -> hlsIdentityURL(UriUtil.resolve(baseUrl, line))
                line.startsWith("#EXT-X-MEDIA:") || line.startsWith("#EXT-X-I-FRAME-STREAM-INF:") || line.startsWith("#EXT-X-IMAGE-STREAM-INF:") -> {
                    val prefix = line.substringBefore(':') + ":"
                    prefix + Regex("(^|,)URI=\"([^\"]*)\"").replace(line.substringAfter(':')) { match ->
                        match.groupValues[1] + "URI=\"" + hlsIdentityURL(UriUtil.resolve(baseUrl, match.groupValues[2])) + "\""
                    }
                }
                else -> line
            } }
            .joinToString("\n")
        return digest(hlsIdentityURL(baseUrl).toByteArray(Charsets.UTF_8) + byteArrayOf(0) + identity.toByteArray(Charsets.UTF_8))
    }
    private fun hlsIdentityURL(value: String): String {
        val uri = Uri.parse(value)
        val host = uri.host ?: return value
        if (uri.scheme != "https" || !host.startsWith("manifest-") || !host.endsWith(".mux.com") ||
            uri.path?.endsWith("/rendition.m3u8") != true) return value
        val parts = uri.encodedQuery?.split('&') ?: return value
        fun name(part: String) = Uri.decode(part.substringBefore('='))
        if (parts.none { name(it) == "signature" } || parts.none { name(it) == "expires" }) return value
        val retained = parts.filter { name(it) !in setOf("signature", "expires") }.joinToString("&")
        return uri.buildUpon().encodedQuery(retained.takeIf { it.isNotEmpty() }).build().toString()
    }
    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
