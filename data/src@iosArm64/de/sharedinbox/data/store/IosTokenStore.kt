package de.sharedinbox.data.store

import de.sharedinbox.core.repository.StoredCredentials
import de.sharedinbox.core.repository.TokenStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import platform.Foundation.NSUserDefaults

/**
 * iOS credential store — persists to NSUserDefaults.
 * TODO Phase 12: replace with Keychain via Security.framework.
 */
class IosTokenStore : TokenStore {

    private val json = Json { prettyPrint = false }
    private val defaults = NSUserDefaults.standardUserDefaults
    private val storeKey = "sharedinbox_credentials"

    @Serializable
    private data class CredentialEntry(
        val accountId: String,
        val username: String,
        val password: String,
    )

    @Serializable
    private data class CredentialStore(
        val entries: Map<String, CredentialEntry> = emptyMap(),
    )

    override suspend fun saveCredentials(accountId: String, username: String, password: String) {
        val store = load()
        save(store.copy(entries = store.entries + (accountId to CredentialEntry(accountId, username, password))))
    }

    override suspend fun loadCredentials(accountId: String): StoredCredentials? {
        val entry = load().entries[accountId] ?: return null
        return StoredCredentials(entry.accountId, entry.username, entry.password)
    }

    override suspend fun clearCredentials(accountId: String) {
        val store = load()
        save(store.copy(entries = store.entries - accountId))
    }

    private fun load(): CredentialStore {
        val text = defaults.stringForKey(storeKey) ?: return CredentialStore()
        return runCatching { json.decodeFromString<CredentialStore>(text) }.getOrDefault(CredentialStore())
    }

    private fun save(store: CredentialStore) {
        defaults.setObject(json.encodeToString(store), storeKey)
    }
}

