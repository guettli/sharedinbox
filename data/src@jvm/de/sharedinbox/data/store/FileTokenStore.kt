package de.sharedinbox.data.store

import de.sharedinbox.core.repository.StoredCredentials
import de.sharedinbox.core.repository.TokenStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText

/**
 * JVM implementation of [TokenStore].
 *
 * Credentials are stored as plain JSON at [storePath].
 * Default: ~/.sharedinbox/credentials.json
 *
 * TODO Phase 11: encrypt with AES-GCM using a key derived from the OS keyring.
 */
class FileTokenStore(
    private val storePath: Path = defaultStorePath(),
) : TokenStore {
    private val json = Json { prettyPrint = false }

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

    override suspend fun saveCredentials(
        accountId: String,
        username: String,
        password: String,
    ) {
        val store = load()
        val updated =
            store.copy(
                entries = store.entries + (accountId to CredentialEntry(accountId, username, password)),
            )
        save(updated)
    }

    override suspend fun loadCredentials(accountId: String): StoredCredentials? {
        val entry = load().entries[accountId] ?: return null
        return StoredCredentials(
            accountId = entry.accountId,
            username = entry.username,
            password = entry.password,
        )
    }

    override suspend fun clearCredentials(accountId: String) {
        val store = load()
        save(store.copy(entries = store.entries - accountId))
    }

    private fun load(): CredentialStore {
        if (!storePath.exists()) return CredentialStore()
        val text = storePath.readText()
        if (text.isBlank()) return CredentialStore()
        return json.decodeFromString(text)
    }

    private fun save(store: CredentialStore) {
        storePath.parent.createDirectories()
        storePath.writeText(json.encodeToString(store))
        Files.setPosixFilePermissions(
            storePath,
            setOf(
                java.nio.file.attribute.PosixFilePermission.OWNER_READ,
                java.nio.file.attribute.PosixFilePermission.OWNER_WRITE,
            ),
        )
    }

    companion object {
        fun defaultStorePath(): Path = Path.of(System.getProperty("user.home"), ".sharedinbox", "credentials.json")
    }
}
