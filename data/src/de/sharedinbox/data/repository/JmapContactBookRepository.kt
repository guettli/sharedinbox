package de.sharedinbox.data.repository

import de.sharedinbox.core.repository.Contact
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient

/**
 * Fetches contacts from the JMAP Contacts API (RFC 9610).
 *
 * Returns an empty list when the server does not support JMAP Contacts,
 * or when no credentials are available for [accountId].
 */
class JmapContactBookRepository(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
) {
    suspend fun searchContacts(
        accountId: String,
        query: String,
    ): List<Contact> {
        if (query.length < 2) return emptyList()
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull() ?: return emptyList()
        val credentials = tokenStore.loadCredentials(accountId) ?: return emptyList()
        val httpClient = createHttpClient(credentials.username, credentials.password)
        return try {
            val apiClient = JmapApiClient(account.api_url, httpClient)
            apiClient
                .searchContactCards(account.jmap_account_id, query)
                .flatMap { card ->
                    card.emails.values.map { emailEntry ->
                        Contact(name = card.fullName, email = emailEntry.address)
                    }
                }
        } finally {
            httpClient.close()
        }
    }
}
