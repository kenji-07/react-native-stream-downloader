package org.openoffline.streamdownloader.drm

import android.content.Context
import android.util.AtomicFile
import java.io.File
import org.openoffline.streamdownloader.core.DownloadFailure
import org.openoffline.streamdownloader.core.OfflineDrm
import org.openoffline.streamdownloader.storage.ProtectedStorage

/** Survives the gap between platform license acquisition and the public asset commit. */
internal class RightsStore(context: Context) {
    data class Rights(val drm: OfflineDrm, val fingerprint: String, val licenseServer: String,
        val headers: Map<String, String>, val removing: Boolean = false)
    private val directory = File(context.noBackupFilesDir, "stream-downloader/rights")
    private fun file(id: String): AtomicFile {
        require(id.matches(Regex("[A-Za-z0-9_-]+")))
        return AtomicFile(File(directory, "$id.rights"))
    }

    @Synchronized fun read(id: String): Rights? {
        val file = file(id)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        try {
            val data = ProtectedStorage.open(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) }, "rights:$id")
            @Suppress("UNCHECKED_CAST") val headers = data["headers"] as Map<String, String>
            return Rights(OfflineDrm(data["scheme"] as String, data["keySetId"] as String),
                data["fingerprint"] as String, data["licenseServer"] as String, headers, data["removing"] == true)
        } catch (error: DownloadFailure) { throw error }
        catch (_: Exception) { throw DownloadFailure("E_DRM_STORAGE", "The offline rights journal could not be read.") }
    }

    @Synchronized fun put(id: String, rights: Rights) {
        if (!directory.exists() && !directory.mkdirs()) throw DownloadFailure("E_DRM_STORAGE", "The offline rights journal could not be created.")
        val encrypted = ProtectedStorage.seal(mapOf("scheme" to rights.drm.scheme, "keySetId" to rights.drm.keySetId,
            "fingerprint" to rights.fingerprint, "licenseServer" to rights.licenseServer, "headers" to rights.headers,
            "removing" to rights.removing), "rights:$id")
        val file = file(id)
        val output = try { file.startWrite() } catch (_: Exception) { throw DownloadFailure("E_DRM_STORAGE", "The offline rights journal could not be written.") }
        try { output.write(encrypted.toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
        catch (_: Exception) { file.failWrite(output); throw DownloadFailure("E_DRM_STORAGE", "The offline rights journal could not be saved.") }
    }

    @Synchronized fun pendingReleases(): List<String> = directory.listFiles()?.mapNotNull {
        // AtomicFile can leave only its backup when a process stops during a write.
        // Include that identity so openRead() can restore and replay its tombstone.
        when {
            it.name.endsWith(".rights.bak") -> it.name.removeSuffix(".rights.bak")
            it.name.endsWith(".rights") -> it.name.removeSuffix(".rights")
            else -> null
        }
    }?.distinct()?.filter { id ->
        // One unreadable journal must not prevent release of unrelated assets.
        try { read(id)?.removing == true } catch (_: Exception) { false }
    } ?: emptyList()
    @Synchronized fun remove(id: String) { file(id).delete() }
}
