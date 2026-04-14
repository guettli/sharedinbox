package de.sharedinbox.core.repository

/**
 * Secure per-account credential storage.
 * expect/actual implementations:
 *   Android  — EncryptedSharedPreferences
 *   iOS      — Keychain via Security.framework interop
 *   JVM      — local encrypted file (java.util.prefs or AES-GCM file)
 */
interface TokenStore {
    suspend fun saveCredentials(
        accountId: String,
        username: String,
        password: String,
    )

    suspend fun loadCredentials(accountId: String): StoredCredentials?

    suspend fun clearCredentials(accountId: String)
}

data class StoredCredentials(
    val accountId: String,
    val username: String,
    val password: String,
)
