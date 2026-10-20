package de.jasonstream.player

import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Verschlüsselt Geheimnisse (Zugangsdaten, PIN-Hash) mit AES-256-GCM.
 * Der Schlüssel wird im Android-Keystore erzeugt und verlässt ihn nie.
 * Arbeitet in einem Hintergrund-Thread, damit die Oberfläche nie blockiert.
 */
object SecureBox {
    private const val ALIAS = "jason_stream_master_v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val PREFIX = "k1:"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "de.jasonstream.player/secure")
            .setMethodCallHandler { call, result ->
                val value = call.argument<String>("value")
                if (value == null) {
                    result.error("arg", "value fehlt", null); return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val out = when (call.method) {
                            "encrypt" -> encrypt(value)
                            "decrypt" -> decrypt(value)
                            else -> null
                        }
                        main.post {
                            if (out == null) result.notImplemented() else result.success(out)
                        }
                    } catch (e: Exception) {
                        main.post { result.error("crypto", e.javaClass.simpleName, null) }
                    }
                }
            }
    }

    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun encrypt(plain: String): String {
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.ENCRYPT_MODE, key())
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        return PREFIX + b64(c.iv) + ":" + b64(ct)
    }

    /** Auch für den Aufnahme-Dienst (Adresse liegt nur verschlüsselt vor). */
    fun decrypt(data: String): String {
        require(data.startsWith(PREFIX)) { "format" }
        val parts = data.removePrefix(PREFIX).split(":")
        require(parts.size == 2) { "format" }
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, unb64(parts[0])))
        return String(c.doFinal(unb64(parts[1])), Charsets.UTF_8)
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun unb64(s: String) = Base64.decode(s, Base64.NO_WRAP)
}
