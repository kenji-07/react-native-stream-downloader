package org.openoffline.streamdownloader.drm

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import androidx.media3.exoplayer.drm.MediaDrmCallbackException
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal class DrmTransportFailure(val provisioning: Boolean, val status: Int? = null) : IOException("The DRM request failed.")

/** Entitlement headers never reach media, provisioning, or a redirected host. */
@UnstableApi
internal class LicenseTransport(private val licenseServer: String, private val headers: Map<String, String>,
    private val stopped: () -> Boolean = { false }) : MediaDrmCallback {
    companion object {
        private val deadlines = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "OfflineLicenseDeadline").apply { isDaemon = true }
        }
    }
    override fun executeProvisionRequest(uuid: UUID, request: ExoMediaDrm.ProvisionRequest): ByteArray {
        val separator = if (request.defaultUrl.contains('?')) "&" else "?"
        return post(request.defaultUrl + separator + "signedRequest=" + request.data.toString(Charsets.UTF_8),
            null, emptyMap(), true)
    }

    override fun executeKeyRequest(uuid: UUID, request: ExoMediaDrm.KeyRequest): ByteArray {
        val properties = mutableMapOf("Content-Type" to if (uuid == C.PLAYREADY_UUID) "text/xml" else "application/octet-stream")
        if (uuid == C.PLAYREADY_UUID) properties["SOAPAction"] = "http://schemas.microsoft.com/DRM/2007/03/protocols/AcquireLicense"
        properties.putAll(headers)
        // The app's configured endpoint wins over URLs embedded in untrusted manifests/PSSH.
        return post(licenseServer, request.data, properties, false)
    }

    private fun post(endpoint: String, body: ByteArray?, properties: Map<String, String>, provisioning: Boolean): ByteArray {
        val spec = DataSpec.Builder().setUri(endpoint).setHttpMethod(DataSpec.HTTP_METHOD_POST).setHttpBody(body).build()
        val active = AtomicReference<HttpURLConnection?>()
        val aborted = AtomicBoolean(false)
        val deadline = System.nanoTime() + 60_000_000_000L
        // HttpURLConnection has no write timeout. Closing the connection also
        // bounds a blocked request body write and promptly observes queue stops.
        val guard = deadlines.scheduleWithFixedDelay({
            if (stopped() || System.nanoTime() >= deadline) {
                aborted.set(true)
                active.get()?.disconnect()
            }
        }, 250, 250, TimeUnit.MILLISECONDS)
        try {
            val original = URL(endpoint)
            var target = original
            repeat(6) { redirect ->
                if (aborted.get() || stopped() || System.nanoTime() >= deadline) throw DrmTransportFailure(provisioning)
                if (target.protocol !in listOf("http", "https")) throw DrmTransportFailure(provisioning)
                val connection = target.openConnection() as HttpURLConnection
                active.set(connection)
                try {
                    if (aborted.get()) throw DrmTransportFailure(provisioning)
                    connection.instanceFollowRedirects = false
                    connection.connectTimeout = 15_000; connection.readTimeout = 15_000
                    connection.requestMethod = "POST"
                    properties.forEach { (name, value) -> connection.setRequestProperty(name, value) }
                    if (body != null) {
                        connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size)
                        connection.outputStream.use { it.write(body) }
                    }
                    val status = connection.responseCode
                    if (status in listOf(307, 308)) {
                        val location = connection.getHeaderField("Location") ?: throw DrmTransportFailure(provisioning, status)
                        val next = URL(target, location)
                        if (redirect == 5 || next.protocol != original.protocol || next.host != original.host || next.port != original.port) {
                            throw DrmTransportFailure(provisioning, status)
                        }
                        target = next
                    } else {
                        if (status !in 200..299) throw DrmTransportFailure(provisioning, status)
                        val output = ByteArrayOutputStream()
                        connection.inputStream.use { input ->
                            val buffer = ByteArray(16_384)
                            while (true) {
                                if (aborted.get() || stopped() || System.nanoTime() >= deadline) throw DrmTransportFailure(provisioning)
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (output.size() + count > 16 * 1024 * 1024) throw DrmTransportFailure(provisioning)
                                output.write(buffer, 0, count)
                            }
                        }
                        return output.toByteArray().also { if (it.isEmpty()) throw DrmTransportFailure(provisioning) }
                    }
                } finally { active.compareAndSet(connection, null); connection.disconnect() }
            }
            throw DrmTransportFailure(provisioning)
        } catch (error: Exception) {
            throw MediaDrmCallbackException(spec, Uri.parse(endpoint), emptyMap(), 0,
                if (error is DrmTransportFailure) error else DrmTransportFailure(provisioning))
        } finally { guard.cancel(false); active.getAndSet(null)?.disconnect() }
    }
}

/** Playback and rights queries have no network path, including provisioning and renewal. */
@UnstableApi
internal object OfflineOnlyDrmCallback : MediaDrmCallback {
    private fun denied(): Nothing {
        val uri = Uri.parse("rnv-offline://license/unavailable")
        throw MediaDrmCallbackException(DataSpec(uri), uri, emptyMap(), 0,
            IOException("Offline playback cannot provision, renew or acquire a streaming license."))
    }
    override fun executeProvisionRequest(uuid: UUID, request: ExoMediaDrm.ProvisionRequest): ByteArray = denied()
    override fun executeKeyRequest(uuid: UUID, request: ExoMediaDrm.KeyRequest): ByteArray = denied()
}
