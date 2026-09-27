package org.openoffline.streamdownloader.storage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.openoffline.streamdownloader.core.DownloadFailure

/** Encrypts entitlement data at rest with an app/device-bound, non-exportable key. */
internal object ProtectedStorage {
    private const val ALIAS = "org.openoffline.streamdownloader.entitlements.v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    @Synchronized private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }

    fun seal(value: Map<String, Any?>, identity: String): String = try {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()); updateAAD(identity.toByteArray()) }
        val encrypted = cipher.doFinal(Json.encode(value).toByteArray(Charsets.UTF_8))
        Base64.encodeToString(byteArrayOf(1, cipher.iv.size.toByte()) + cipher.iv + encrypted, Base64.NO_WRAP)
    } catch (_: Exception) { throw DownloadFailure("E_DRM_STORAGE", "The device could not protect offline entitlement data.") }

    fun open(value: String, identity: String): Map<String, Any?> = try {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        require(bytes.size > 30 && bytes[0].toInt() == 1)
        val size = bytes[1].toInt() and 255
        require(size in 12..16 && bytes.size > size + 18)
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(2, size + 2)))
            updateAAD(identity.toByteArray())
        }
        Json.decodeObject(cipher.doFinal(bytes.copyOfRange(size + 2, bytes.size)).toString(Charsets.UTF_8))
    } catch (_: Exception) { throw DownloadFailure("E_DRM_STORAGE", "Offline entitlement data is unavailable on this app installation.") }
}
