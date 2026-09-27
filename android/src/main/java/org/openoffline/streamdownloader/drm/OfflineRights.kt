package org.openoffline.streamdownloader.drm

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.media.MediaDrm
import android.os.Build
import android.util.Base64
import androidx.media3.common.C
import androidx.media3.common.DrmInitData
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionEventListener
import androidx.media3.exoplayer.drm.DrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import androidx.media3.exoplayer.drm.OfflineLicenseHelper
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.extractor.mp4.PsshAtomUtil
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.Executor
import java.util.concurrent.ConcurrentHashMap
import org.openoffline.streamdownloader.core.DownloadFailure
import org.openoffline.streamdownloader.core.OfflineDrm
import org.openoffline.streamdownloader.core.Record

/** Owns platform-issued persistent key-set references, never content keys. */
@UnstableApi
internal class OfflineRights(private val context: Context, private val executor: Executor, private val networkAllowed: () -> Boolean = { true }) {
    private val store = RightsStore(context)
    private val releasing = ConcurrentHashMap.newKeySet<String>()

    fun prepare(record: Record, manifestFingerprint: String, mediaKind: String, formats: List<Format>, stopped: () -> Boolean): OfflineDrm {
        val config = record.options["drm"] as? Map<*, *>
            ?: throw DownloadFailure("E_DRM_REQUIRED", "The selected media requires an application-provided offline license endpoint.")
        val endpoint = config["licenseServer"] as? String
            ?: throw DownloadFailure("E_INVALID_DRM", "Android offline DRM requires a licenseServer.")
        @Suppress("UNCHECKED_CAST") val headers = config["headers"] as? Map<String, String> ?: emptyMap()
        val (uuid, format) = choose(formats, mediaKind)
        val fingerprint = record.fingerprint + ":" + manifestFingerprint + ":" + initializationFingerprint(format)
        store.read(record.id)?.let { existing ->
            if (existing.removing || existing.fingerprint != fingerprint || existing.drm.scheme != uuid.toString()) {
                throw DownloadFailure("E_DRM_CONTEXT_CHANGED", "The stored offline license belongs to a different media or entitlement context.")
            }
            verify(existing.drm)
            return existing.drm
        }
        if (stopped()) throw InterruptedException()
        val helper = helper(uuid, LicenseTransport(endpoint, headers) { stopped() || !networkAllowed() })
        try {
            val keySetId = try { helper.downloadLicense(format) }
            catch (error: Exception) { throw failure(error) }
            if (keySetId.isEmpty()) throw DownloadFailure("E_DRM_OFFLINE_UNSUPPORTED", "The provider or device did not issue persistent rights.")
            val drm = OfflineDrm(uuid.toString(), Base64.encodeToString(keySetId, Base64.NO_WRAP))
            try {
                // Write before observing cancellation: a late license result must remain owned.
                store.put(record.id, RightsStore.Rights(drm, fingerprint, endpoint, headers))
            } catch (error: Exception) {
                try { helper.releaseLicense(keySetId) } catch (_: Exception) {
                    if (Build.VERSION.SDK_INT >= 29) try {
                        MediaDrm(uuid).let { platform -> try { platform.removeOfflineLicense(keySetId) } finally { platform.close() } }
                    } catch (_: Exception) { /* Preserve the original storage failure. */ }
                }
                throw error
            }
            verify(drm)
            return drm
        } finally { helper.release() }
    }

    fun current(id: String): OfflineDrm? = store.read(id)?.takeIf { !it.removing }?.drm

    fun status(id: String): Map<String, Any?> {
        val rights = store.read(id)?.takeIf { !it.removing }
            ?: throw DownloadFailure("E_DRM_STORAGE", "The persistent rights journal is missing.")
        val uuid = UUID.fromString(rights.drm.scheme)
        val result = mutableMapOf<String, Any?>("id" to id, "scheme" to if (uuid == C.WIDEVINE_UUID) "widevine" else "playready", "state" to "unknown", "checkedAt" to System.currentTimeMillis())
        if (uuid != C.WIDEVINE_UUID) { verify(rights.drm); return result }
        val helper = helper(uuid, OfflineOnlyDrmCallback)
        try {
            val remaining = helper.getLicenseDurationRemainingSec(Base64.decode(rights.drm.keySetId, Base64.NO_WRAP))
            result["state"] = if (remaining.first == 0L || remaining.second == 0L) "expired" else if (remaining.first > 0 && remaining.second > 0) "valid" else "unknown"
            if (remaining.first in 0..9007199254740991L) result["licenseDurationRemainingSeconds"] = remaining.first
            if (remaining.second in 0..9007199254740991L) result["playbackDurationRemainingSeconds"] = remaining.second
            val seconds = minOf(remaining.first, remaining.second)
            val now = System.currentTimeMillis()
            if (seconds in 0..((9007199254740991L - now) / 1000)) result["expiresAt"] = now + seconds * 1000
            return result
        } catch (error: Exception) { throw failure(error) }
        finally { helper.release() }
    }

    fun renew(id: String, config: Map<String, Any?>?): OfflineDrm {
        val existing = store.read(id)?.takeIf { !it.removing }
            ?: throw DownloadFailure("E_DRM_STORAGE", "The persistent rights journal is missing.")
        val endpoint = config?.get("licenseServer") as? String ?: existing.licenseServer
        @Suppress("UNCHECKED_CAST") val headers = config?.get("headers") as? Map<String, String> ?: if (config == null) existing.headers else emptyMap()
        if (!networkAllowed()) throw DownloadFailure("E_NETWORK_POLICY", "Connect to Wi-Fi before renewing rights.", true)
        val helper = helper(UUID.fromString(existing.drm.scheme), LicenseTransport(endpoint, headers) { !networkAllowed() })
        try {
            val renewed = try { helper.renewLicense(Base64.decode(existing.drm.keySetId, Base64.NO_WRAP)) } catch (error: Exception) { throw failure(error) }
            if (renewed.isEmpty()) throw DownloadFailure("E_DRM_LICENSE", "The provider did not return renewed persistent rights.")
            val drm = OfflineDrm(existing.drm.scheme, Base64.encodeToString(renewed, Base64.NO_WRAP))
            // This journal is authoritative if the process exits before the asset row is updated.
            store.put(id, existing.copy(drm = drm, licenseServer = endpoint, headers = headers))
            return drm
        } finally { helper.release() }
    }

    private fun choose(formats: List<Format>, mediaKind: String): Pair<UUID, Format> {
        val protected = formats.mapNotNull { it.drmInitData }
        if (protected.isEmpty()) throw DownloadFailure("E_DRM_INIT_DATA", "Persistent license initialization data is missing from the selected media.")
        val modes = protected.mapNotNull { it.schemeType }.toSet()
        if (modes.any { it != C.CENC_TYPE_cenc && it != C.CENC_TYPE_cbcs } || modes.size > 1) {
            throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "The selected encryption modes cannot share one offline DRM session.")
        }
        if (C.CENC_TYPE_cbcs in modes && Build.VERSION.SDK_INT < 25) {
            throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "Widevine CBCS requires Android API 25 or later.")
        }
        fun signaledEverywhere(uuid: UUID) = protected.all { data -> (0 until data.schemeDataCount).any { data[it].matches(uuid) } }
        val uuid = when {
            signaledEverywhere(C.WIDEVINE_UUID) && MediaDrm.isCryptoSchemeSupported(C.WIDEVINE_UUID) -> C.WIDEVINE_UUID
            signaledEverywhere(C.PLAYREADY_UUID) -> {
                val television = (context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                if (mediaKind != "dash" || !television || !MediaDrm.isCryptoSchemeSupported(C.PLAYREADY_UUID) || C.CENC_TYPE_cbcs in modes) {
                    throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "PlayReady offline acquisition requires DASH CENC and a compatible Android TV implementation.")
                }
                C.PLAYREADY_UUID
            }
            else -> throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "The device has no compatible persistent DRM scheme for all selected tracks.")
        }
        val data = protected.flatMap { init -> (0 until init.schemeDataCount).map { init[it] } }
            .filter { it.matches(uuid) && it.data?.isNotEmpty() == true }
            .map { DrmInitData.SchemeData(uuid, it.mimeType, it.data) }.distinct()
        if (data.isEmpty()) throw DownloadFailure("E_DRM_INIT_DATA", "The selected media has no usable persistent license initialization data.")
        // Media3 combines Widevine PSSH only on API 28+. Other cases would silently
        // acquire just the first independently signaled key set.
        if (data.size > 1 && (uuid != C.WIDEVINE_UUID || Build.VERSION.SDK_INT < 28 ||
                data.any { it.mimeType != data.first().mimeType || !PsshAtomUtil.isPsshAtom(it.data!!) })) {
            throw DownloadFailure("E_UNSUPPORTED_CAPABILITY", "These selected tracks require multiple DRM initialization records that this device cannot acquire as one offline license.")
        }
        val first = formats.first { it.drmInitData != null }
        return uuid to first.buildUpon().setDrmInitData(DrmInitData(modes.firstOrNull(), data)).build()
    }

    private fun initializationFingerprint(format: Format): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val init = requireNotNull(format.drmInitData)
        fun update(bytes: ByteArray) {
            // Length prefixes keep differently partitioned initialization records distinct.
            digest.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.size).array())
            digest.update(bytes)
        }
        update((init.schemeType ?: "").toByteArray(Charsets.UTF_8))
        for (index in 0 until init.schemeDataCount) {
            update(init[index].uuid.toString().toByteArray(Charsets.UTF_8))
            update(init[index].mimeType.toByteArray(Charsets.UTF_8))
            update(init[index].data ?: byteArrayOf())
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Query mode restores rights but never applies Media3's automatic near-expiry renewal. */
    private fun verify(drm: OfflineDrm) {
        val uuid = UUID.fromString(drm.scheme)
        val keySetId = Base64.decode(drm.keySetId, Base64.NO_WRAP)
        if (uuid == C.WIDEVINE_UUID) {
            val helper = helper(uuid, OfflineOnlyDrmCallback)
            try {
                val remaining = helper.getLicenseDurationRemainingSec(keySetId)
                if (remaining.first <= 0 || remaining.second <= 0) {
                    throw DownloadFailure("E_DRM_LICENSE_EXPIRED", "The offline license has expired or has no remaining playback rights.")
                }
            } catch (error: Exception) { throw failure(error) }
            finally { helper.release() }
        } else {
            // PlayReady exposes no portable Widevine-style duration fields. Actual
            // offline key restoration is the gate; the CDM enforces its own policy.
            try {
                val platform = MediaDrm(uuid)
                try {
                    val session = platform.openSession()
                    try { platform.restoreKeys(session, keySetId); platform.queryKeyStatus(session) }
                    finally { platform.closeSession(session) }
                } finally { platform.release() }
            } catch (error: Exception) { throw failure(error) }
        }
    }

    fun valid(id: String, drm: OfflineDrm): Boolean = try {
        store.read(id)?.let { !it.removing && it.drm == drm } == true
    } catch (_: Exception) { false }

    fun verifyForCommit(id: String, drm: OfflineDrm) {
        if (!valid(id, drm)) throw DownloadFailure("E_DRM_STORAGE", "The downloaded media has no saved persistent rights.")
        // A lengthy media transfer can outlive a short provider entitlement.
        verify(drm)
    }

    /** Persist the release intent before media deletion; networking runs outside the queue actor. */
    fun remove(id: String) {
        val rights = store.read(id) ?: return
        if (!rights.removing) store.put(id, rights.copy(removing = true))
        scheduleRelease(id)
    }

    fun retryPendingReleases() {
        executor.execute { try { store.pendingReleases().forEach(::scheduleRelease) } catch (_: Exception) { /* Keep unreadable journals for explicit recovery. */ } }
    }

    private fun scheduleRelease(id: String) {
        if (!releasing.add(id)) return
        executor.execute {
            try {
                val rights = store.read(id) ?: return@execute
                if (!rights.removing) return@execute
                val helper = helper(UUID.fromString(rights.drm.scheme), LicenseTransport(rights.licenseServer, rights.headers) { !networkAllowed() })
                try { helper.releaseLicense(Base64.decode(rights.drm.keySetId, Base64.NO_WRAP)) }
                finally { helper.release() }
                store.remove(id)
            } catch (_: Exception) {
                // Offline/revoked endpoints may not acknowledge release. Retain the
                // encrypted tombstone and retry on the next native runtime startup.
            } finally { releasing.remove(id) }
        }
    }

    fun playbackProvider(drm: OfflineDrm?): DrmSessionManagerProvider = DrmSessionManagerProvider {
        if (drm == null) DrmSessionManager.DRM_UNSUPPORTED else manager(UUID.fromString(drm.scheme), OfflineOnlyDrmCallback).apply {
            // In Media3 1.4.1 QUERY restores STATE_OPENED_WITH_KEYS just as PLAYBACK
            // does, but omits PLAYBACK's renewal request during the last 60 seconds.
            // Secure decoding and license expiry continue to be enforced by the CDM.
            setMode(DefaultDrmSessionManager.MODE_QUERY, Base64.decode(drm.keySetId, Base64.NO_WRAP))
        }
    }

    fun configuration(drm: OfflineDrm): MediaItem.DrmConfiguration = MediaItem.DrmConfiguration.Builder(UUID.fromString(drm.scheme))
        .setKeySetId(Base64.decode(drm.keySetId, Base64.NO_WRAP)).setMultiSession(false).build()

    private fun helper(uuid: UUID, callback: MediaDrmCallback) = OfflineLicenseHelper(manager(uuid, callback), DrmSessionEventListener.EventDispatcher())
    private fun manager(uuid: UUID, callback: MediaDrmCallback) = DefaultDrmSessionManager.Builder()
        .setUuidAndExoMediaDrmProvider(uuid, FrameworkMediaDrm.DEFAULT_PROVIDER)
        .setMultiSession(false).setPlayClearSamplesWithoutKeys(false)
        .setSessionKeepaliveMs(C.TIME_UNSET).setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(0)).build(callback)

    private fun failure(error: Exception): DownloadFailure {
        if (error is DownloadFailure) return error
        val causes = generateSequence<Throwable>(error) { it.cause }.take(16).toList()
        val transport = causes.filterIsInstance<DrmTransportFailure>().firstOrNull()
        return when {
            causes.any { it is android.media.DeniedByServerException } || transport?.status in listOf(401, 403) ->
                DownloadFailure("E_DRM_LICENSE_DENIED", "The provider refused persistent rights for this media.")
            transport?.provisioning == true || causes.any { it is android.media.NotProvisionedException } ->
                DownloadFailure("E_DRM_PROVISIONING", "The device could not complete DRM provisioning.", transport?.status == null || transport.status in listOf(408, 429) || transport.status in 500..599)
            causes.any { it is androidx.media3.exoplayer.drm.KeysExpiredException } ->
                DownloadFailure("E_DRM_LICENSE_EXPIRED", "The offline license has expired.")
            transport != null -> DownloadFailure("E_DRM_LICENSE_REQUEST", "The persistent license request failed.", transport.status == null || transport.status in listOf(408, 429) || transport.status in 500..599)
            else -> DownloadFailure("E_DRM_OFFLINE_UNSUPPORTED", "The device or provider could not restore persistent playback rights.")
        }
    }
}
