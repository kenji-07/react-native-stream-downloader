package org.openoffline.streamdownloader.media

import java.text.Normalizer

/** A display filename only. Storage ownership continues to use the generated asset ID. */
internal object AssetFileName {
    fun mp4(title: String?): String {
        if (title.isNullOrBlank()) return "video.mp4"
        val normalized = Normalizer.normalize(title, Normalizer.Form.NFKC)
        val safe = normalized.map { character ->
            if (character.isISOControl() || character in "/\\:?*|\"<>") '_' else character
        }.joinToString("").trim().trim('.')
        val stem = (if (safe.endsWith(".mp4", ignoreCase = true)) safe.dropLast(4) else safe).trim().trim('.')
        if (stem.isEmpty()) return "video.mp4"
        val end = stem.offsetByCodePoints(0, minOf(80, stem.codePointCount(0, stem.length)))
        return stem.substring(0, end) + ".mp4"
    }
}
