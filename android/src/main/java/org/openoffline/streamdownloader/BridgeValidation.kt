package org.openoffline.streamdownloader

import java.net.URI
import java.security.MessageDigest
import org.openoffline.streamdownloader.core.DownloadFailure
import org.openoffline.streamdownloader.storage.Json

internal object BridgeValidation {
    private fun invalid(message: String): Nothing = throw DownloadFailure("E_INVALID_ARGUMENT", message)
    fun string(value: Any?): String = (value as? String)?.takeIf { it.isNotEmpty() } ?: invalid("Expected a nonempty string.")
    fun number(value: Any?, min: Long = 0, max: Long = 9007199254740991): Long {
        val n = (value as? Number)?.toDouble() ?: invalid("Expected a number.")
        if (!n.isFinite() || n % 1 != 0.0 || n < min || n > max) invalid("Number is outside the supported integer range.")
        return n.toLong()
    }
    fun url(value: Any?): String {
        val text = string(value)
        val uri = try { URI(text) } catch (_: Exception) { throw DownloadFailure("E_INVALID_URL", "Invalid media URL.") }
        if (uri.scheme?.lowercase() !in listOf("http", "https") || uri.host.isNullOrEmpty() || uri.userInfo != null || uri.port !in -1..65535 || uri.port == 0) {
            throw DownloadFailure("E_INVALID_URL", "An HTTP or HTTPS URL without embedded credentials is required.")
        }
        return text
    }
    @Suppress("UNCHECKED_CAST") fun map(value: Any?): Map<String, Any?> = (value as? Map<*, *>)?.takeIf { it.keys.all { key -> key is String } } as? Map<String, Any?> ?: invalid("Expected an object.")
    private fun keys(value: Map<String, Any?>, allowed: Set<String>) { if ((value.keys - allowed).isNotEmpty()) invalid("Unsupported object property.") }

    fun params(method: String, value: Map<String, Any?>): Map<String, Any?> = when (method) {
        "registerPlugin", "disablePlugin", "getConfig", "getDownloadsStatus", "getDownloadedAssets", "cancelAllDownloads", "deleteAllDownloadedAssets", "deleteAllQueuedItems" -> { keys(value, emptySet()); emptyMap() }
        "setConfig" -> {
            val config = map(value["config"]); keys(config, setOf("maxParallelDownloads", "updateFrequencyMS", "wifiOnly", "retry"))
            val normalized = config.toMutableMap()
            for (key in listOf("maxParallelDownloads", "updateFrequencyMS")) config[key]?.let { normalized[key] = number(it, 1, Int.MAX_VALUE.toLong()) }
            if (config.containsKey("wifiOnly") && config["wifiOnly"] !is Boolean) invalid("wifiOnly must be boolean.")
            config["retry"]?.let {
                val retry = map(it); keys(retry, setOf("maxRetries", "initialDelayMS", "maxDelayMS"))
                normalized["retry"] = retry.mapValues { (key, value) -> if (key == "maxRetries") number(value, 0, 10) else number(value, 1, 86400000) }
            }
            mapOf("config" to normalized)
        }
        "downloadStream" -> {
            val url = url(value["url"]); val options = options(map(value["options"]))
            val canonical = Json.encode(mapOf("url" to url, "options" to options))
            val fingerprint = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
            mapOf("url" to url, "options" to options, "fingerprint" to fingerprint)
        }
        "getDRMLicenseStatus" -> { keys(value, setOf("id")); mapOf("id" to string(value["id"])) }
        "renewDRMLicense" -> {
            keys(value, setOf("id", "drm"))
            mapOf("id" to string(value["id"])) + if (value.containsKey("drm")) options(mapOf("drm" to value["drm"])) else emptyMap()
        }
        "getAvailableTracks" -> mapOf("url" to url(value["url"]))
        "expireDownloadedAssetAt" -> mapOf("id" to string(value["id"]), "timestamp" to number(value["timestamp"]))
        "cancelDownload", "pauseDownload", "resumeDownload", "getDownloadStatus", "getDownloadedAsset", "deleteDownloadedAsset", "deleteQueuedItem" -> mapOf("id" to string(value["id"]))
        else -> throw DownloadFailure("E_BRIDGE", "Unknown native operation.")
    }

    private fun options(value: Map<String, Any?>): Map<String, Any?> {
        keys(value, setOf("checkStorageBeforeDownload", "expiresAt", "includeAllTracks", "tracks", "drm", "metadata"))
        val result = value.toMutableMap()
        listOf("checkStorageBeforeDownload", "includeAllTracks").forEach { if (value.containsKey(it) && value[it] !is Boolean) invalid("Download flags must be boolean.") }
        value["expiresAt"]?.let { result["expiresAt"] = number(it) }
        value["metadata"]?.let {
            val metadata = map(it)
            if (metadata.containsKey("title") && metadata["title"] !is String) invalid("Metadata title must be a string.")
            if (Json.encode(metadata).toByteArray(Charsets.UTF_8).size > 1048576) invalid("Metadata exceeds 1 MiB.")
        }
        value["tracks"]?.let {
            val tracks = map(it); keys(tracks, setOf("audio", "video", "text"))
            val normalized = tracks.mapValues { entry ->
                (entry.value as? List<*>)?.map { id -> string(id) }?.distinct() ?: invalid("Track IDs must be arrays.")
            }
            if (normalized.size == 3 && normalized.values.all { ids -> ids.isEmpty() }) invalid("At least one media track must be selected.")
            result["tracks"] = normalized
        }
        value["drm"]?.let {
            val drm = map(it); keys(drm, setOf("licenseServer", "certificateUrl", "headers", "callbackRef"))
            if (drm.containsKey("callbackRef")) throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Custom FairPlay callbacks are only supported on iOS.")
            url(drm["licenseServer"])
            drm["certificateUrl"]?.let { certificate -> url(certificate) }
            drm["headers"]?.let { headers -> map(headers).forEach { (key, item) ->
                if (!Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+").matches(key) || item !is String || item.any { c -> c == '\r' || c == '\n' || c == '\u0000' }) invalid("DRM headers are invalid.")
            } }
        }
        return result
    }
}
