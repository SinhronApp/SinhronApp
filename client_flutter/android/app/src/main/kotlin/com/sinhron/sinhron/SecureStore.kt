// ADR-021 on Android — the device key behind `dev.sinhron/keychain`
// (`lib/core/session.dart`).
//
// iOS keeps it in the Keychain, "this device only". Here: an AES-256-GCM key
// generated inside the Android Keystore (it never leaves the secure
// hardware / TEE and isn't in any backup) encrypts each value; the
// ciphertext sits in private SharedPreferences. App backup is off
// (`android:allowBackup="false"`), so nothing of this leaves the phone.

package com.sinhron.sinhron

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences("sinhron_keychain", Context.MODE_PRIVATE)

    fun read(account: String): String? {
        val stored = prefs.getString(account, null) ?: return null
        return try {
            val raw = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, IV_LEN))
            String(cipher.doFinal(raw, IV_LEN, raw.size - IV_LEN), Charsets.UTF_8)
        } catch (e: Exception) {
            null // key gone (app data cleared) — like a missing Keychain item
        }
    }

    fun write(account: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun delete(account: String) {
        prefs.edit().remove(account).apply()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "sinhron-device-key-wrap"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV_LEN = 12

        /** The `dev.sinhron/keychain` channel (`read` / `write` / `delete`) —
         *  needs no screen, so the shared engine has it before Dart starts. */
        fun attach(context: Context, messenger: BinaryMessenger) {
            val store = SecureStore(context.applicationContext)
            MethodChannel(messenger, "dev.sinhron/keychain").setMethodCallHandler { call, result ->
                val account = call.argument<String>("account") ?: return@setMethodCallHandler result.error("bad_args", "account", null)
                try {
                    when (call.method) {
                        "read" -> result.success(store.read(account))
                        "write" -> {
                            store.write(account, call.argument<String>("value") ?: "")
                            result.success(null)
                        }
                        "delete" -> {
                            store.delete(account)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("keystore", e.message, null)
                }
            }
        }
    }
}
