package de.sharedinbox.data.repository

import de.sharedinbox.core.repository.SieveRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient

/**
 * Fetches and saves Sieve scripts via JMAP (draft-ietf-extra-jmap-sieve).
 *
 * Script content is stored as a blob on the server; this class handles the
 * upload→set and get→download round-trips transparently.
 */
class SieveRepositoryImpl(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
) : SieveRepository {
    override suspend fun loadScript(accountId: String): String {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull() ?: return ""
        val credentials = tokenStore.loadCredentials(accountId) ?: return ""
        val httpClient = createHttpClient(credentials.username, credentials.password)
        return try {
            val apiClient = JmapApiClient(account.api_url, httpClient)
            val scripts = apiClient.getSieveScripts(account.jmap_account_id)
            val script = scripts.firstOrNull { it.isActive } ?: scripts.firstOrNull() ?: return ""
            val bytes =
                apiClient.downloadBlob(
                    downloadUrlTemplate = account.download_url,
                    jmapAccountId = account.jmap_account_id,
                    blobId = script.blobId,
                    mimeType = "application/sieve",
                )
            bytes.decodeToString()
        } finally {
            httpClient.close()
        }
    }

    override suspend fun saveScript(
        accountId: String,
        content: String,
    ): String? {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull() ?: return "Account not found"
        val credentials = tokenStore.loadCredentials(accountId) ?: return "No credentials for account"
        val httpClient = createHttpClient(credentials.username, credentials.password)
        return try {
            val apiClient = JmapApiClient(account.api_url, httpClient)
            // Find existing script (if any) so we update rather than create a duplicate.
            val existing = apiClient.getSieveScripts(account.jmap_account_id).firstOrNull()
            val blobId =
                apiClient.uploadBlob(
                    uploadUrl = account.upload_url,
                    jmapAccountId = account.jmap_account_id,
                    content = content.encodeToByteArray(),
                )
            val error =
                apiClient.setSieveScript(
                    jmapAccountId = account.jmap_account_id,
                    scriptId = existing?.id,
                    name = existing?.name ?: "myrules",
                    blobId = blobId,
                )
            error?.let { "${it.type}${if (it.description != null) ": ${it.description}" else ""}" }
        } finally {
            httpClient.close()
        }
    }
}
