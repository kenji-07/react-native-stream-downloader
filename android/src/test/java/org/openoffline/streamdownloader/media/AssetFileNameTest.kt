package org.openoffline.streamdownloader.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AssetFileNameTest {
    @Test fun retainsDisplayTitlesWithoutCreatingPathsOrDuplicateExtensions() {
        assertEquals("video.mp4", AssetFileName.mp4(null))
        assertEquals("video.mp4", AssetFileName.mp4("..."))
        assertEquals("Хичээл 1.mp4", AssetFileName.mp4("Хичээл 1.MP4"))
        assertEquals("_movie_part.mp4", AssetFileName.mp4("../movie/part"))
        assertFalse(AssetFileName.mp4("movie\u0000\n").contains('\u0000'))
        assertEquals(80, AssetFileName.mp4("🙂".repeat(100)).removeSuffix(".mp4").codePointCount(0, 160))
    }
}
