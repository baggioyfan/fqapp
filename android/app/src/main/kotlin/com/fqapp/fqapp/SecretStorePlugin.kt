package com.fqapp.fqapp

import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts stored credentials with a key that only the Android keystore can
 * use, so the ciphertext the Dart side keeps in SharedPreferences is useless
 * off this device.
 *
 * The keystore entry can disappear or be rejected - a restored backup, a
 * dropped keystore - and decryption then fails. That is reported as
 * `SECRET_UNAVAILABLE` so the caller asks for the password again rather than
 * falling back to plain text storage.
 */
class SecretStorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    // Key generation touches disk-backed keystore state; keep it off the
    // platform thread and report the outcome there, as the other plugins do.
    private val executor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "fqapp/secrets")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "encrypt" && call.method != "decrypt") {
            result.notImplemented()
            return
        }
        val value = call.argument<String>("value")
        if (value == null) {
            result.error("SECRET_ARGUMENT", "缺少待处理的内容", null)
            return
        }
        val encrypting = call.method == "encrypt"
        executor.execute {
            val outcome = runCatching {
                if (encrypting) encrypt(value) else decrypt(value)
            }
            mainHandler.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        result.error(
                            "SECRET_UNAVAILABLE",
                            if (encrypting) "无法用系统密钥库保护凭据"
                            else "系统密钥库拒绝解密已保存的凭据",
                            null,
                        )
                    },
                )
            }
        }
    }

    /** `iv || ciphertext || tag`, base64 encoded for SharedPreferences. */
    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        val payload = Base64.decode(value, Base64.NO_WRAP)
        require(payload.size > IV_BYTES) { "stored secret is truncated" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // The IV is generated per operation, so it travels in front of the
        // payload; GCM keeps its tag appended behind it.
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(TAG_BITS, payload, 0, IV_BYTES),
        )
        return String(
            cipher.doFinal(payload, IV_BYTES, payload.size - IV_BYTES),
            Charsets.UTF_8,
        )
    }

    private fun secretKey(): SecretKey {
        val keystore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keystore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "fqapp.stored-credentials"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
    }
}
