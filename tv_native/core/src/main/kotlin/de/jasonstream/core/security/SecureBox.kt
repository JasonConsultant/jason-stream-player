package de.jasonstream.core.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Ver-/Entschlüsselung von Geheimnissen (Zugangsdaten, PIN-Hash).
 * Schnittstelle, damit Speicher und Migration ohne Android-Keystore
 * testbar sind.
 */
interface SecretCipher {
    fun encrypt(plain: String): String

    /** Wirft bei falschem Format oder fehlendem Schlüssel. */
    fun decrypt(cipher: String): String

    /** Alle in einem Durchgang; nicht lesbare → null. */
    fun decryptAll(ciphers: List<String>): List<String?> =
        ciphers.map { runCatching { decrypt(it) }.getOrNull() }
}

/**
 * Port von android/app/src/main/kotlin/de/jasonstream/player/SecureBox.kt –
 * **gleicher Keystore-Alias und gleiches Format**, damit die native App die
 * Geheimnisse der Flutter-App (gleiches Paket → gleicher Keystore) lesen kann:
 *
 *   AES-256-GCM, Schlüssel „jason_stream_master_v1“ im AndroidKeyStore,
 *   Format `k1:` + Base64(IV) + `:` + Base64(Chiffretext inkl. 128-Bit-Tag),
 *   Base64 ohne Zeilenumbrüche (android.util.Base64.NO_WRAP ≙ java.util.Base64).
 *
 * Nicht vom Haupt-Thread aufrufen (Keystore-Zugriffe können dauern).
 */
object SecureBox : SecretCipher {
    const val ALIAS = "jason_stream_master_v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    const val PREFIX = "k1:"

    /** Schlüssel-Referenz pro Prozess merken (Keystore nur einmal laden). */
    @Volatile
    private var cachedKey: SecretKey? = null

    @Synchronized
    private fun key(): SecretKey {
        cachedKey?.let { return it }
        val k = loadOrCreateKey()
        cachedKey = k
        return k
    }

    private fun loadOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun encrypt(plain: String): String = AesGcmFormat.encrypt(key(), plain)
    override fun decrypt(cipher: String): String = AesGcmFormat.decrypt(key(), cipher)

    override fun decryptAll(ciphers: List<String>): List<String?> {
        if (ciphers.isEmpty()) return emptyList()
        val k = key() // Fehler hier → ganzer Aufruf (wie decryptAll in Flutter)
        return ciphers.map { runCatching { AesGcmFormat.decrypt(k, it) }.getOrNull() }
    }
}

/** Das reine Format (ohne Keystore) – auch für JVM-Tests mit eigenem Schlüssel. */
object AesGcmFormat {
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun encrypt(key: SecretKey, plain: String): String {
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.ENCRYPT_MODE, key)
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        return SecureBox.PREFIX + b64(c.iv) + ":" + b64(ct)
    }

    fun decrypt(key: SecretKey, data: String): String {
        require(data.startsWith(SecureBox.PREFIX)) { "format" }
        val parts = data.removePrefix(SecureBox.PREFIX).split(":")
        require(parts.size == 2) { "format" }
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, unb64(parts[0])))
        return String(c.doFinal(unb64(parts[1])), Charsets.UTF_8)
    }

    private fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)
    private fun unb64(s: String) = Base64.getDecoder().decode(s)
}

/** Wie PreviewSecretStore (Dart): `p1:` + Base64 – NUR für Tests/Vorschau. */
object PreviewCipher : SecretCipher {
    override fun encrypt(plain: String) = "p1:" + Base64.getEncoder().encodeToString(plain.toByteArray())
    override fun decrypt(cipher: String): String {
        require(cipher.startsWith("p1:")) { "format" }
        return String(Base64.getDecoder().decode(cipher.substring(3)))
    }
}
