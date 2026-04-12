package de.sharedinbox.core.repository

import de.sharedinbox.core.account.Account
import kotlinx.coroutines.flow.Flow

interface AccountRepository {
    /** Emits the current list of accounts, and re-emits on any change. */
    fun observeAccounts(): Flow<List<Account>>

    /**
     * Discovers the JMAP session at [baseUrl]/.well-known/jmap, authenticates with [username]/[password],
     * persists the account row and credentials, and returns the new [Account].
     * [baseUrl] must include scheme and port, e.g. "https://mail.example.com" or "http://localhost:8080".
     */
    suspend fun addAccount(baseUrl: String, username: String, password: String): Result<Account>

    /**
     * Removes the account and all its data (mailboxes, emails, state tokens)
     * via ON DELETE CASCADE. Also clears stored credentials.
     */
    suspend fun removeAccount(accountId: String)
}
