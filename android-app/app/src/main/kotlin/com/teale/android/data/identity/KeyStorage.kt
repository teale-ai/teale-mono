package com.teale.android.data.identity

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * EncryptedSharedPreferences wrapper for persisting the WAN Ed25519 private key
 * + cached device token.
 */
class KeyStorage(context: Context) {
    private val prefs = run {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "teale_keys",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun getBytes(key: String): ByteArray? =
        prefs.getString(key, null)?.let { android.util.Base64.decode(it, android.util.Base64.NO_WRAP) }

    fun putBytes(key: String, value: ByteArray) {
        prefs.edit().putString(key, android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP)).apply()
    }

    fun getString(key: String): String? = prefs.getString(key, null)
    fun putString(key: String, value: String?) {
        prefs.edit().also { if (value == null) it.remove(key) else it.putString(key, value) }.apply()
    }

    fun getLong(key: String, default: Long = 0L): Long = prefs.getLong(key, default)
    fun putLong(key: String, value: Long) {
        prefs.edit().putLong(key, value).apply()
    }
}
