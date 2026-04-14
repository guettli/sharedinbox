package de.sharedinbox.data.store

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import de.sharedinbox.core.repository.StoredCredentials
import de.sharedinbox.core.repository.TokenStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Android credential store backed by [EncryptedSharedPreferences].
 * Keys are AES256-SIV encrypted; values are AES256-GCM encrypted.
 * Credentials are serialized as JSON and stored under the accountId key.
 */
class AndroidTokenStore(context: Context) : TokenStore {

    private val json = Json { prettyPrint = false }

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "sharedinbox_secure_prefs",
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    @Serializable
    private data class CredentialEntry(
        val accountId: String,
        val username: String,
        val password: String,
    )

    override suspend fun saveCredentials(accountId: String, username: String, password: String) {
        prefs.edit()
            .putString(accountId, json.encodeToString(CredentialEntry(accountId, username, password)))
            .apply()
    }

    override suspend fun loadCredentials(accountId: String): StoredCredentials? {
        val raw = prefs.getString(accountId, null) ?: return null
        val entry = runCatching { json.decodeFromString<CredentialEntry>(raw) }.getOrNull() ?: return null
        return StoredCredentials(entry.accountId, entry.username, entry.password)
    }

    override suspend fun clearCredentials(accountId: String) {
        prefs.edit().remove(accountId).apply()
    }
}
