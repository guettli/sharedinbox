package de.sharedinbox.core.repository

import de.sharedinbox.core.account.Account
import de.sharedinbox.core.jmap.JmapCapability
import kotlinx.coroutines.flow.Flow

interface AccountRepository {
    /** Emits the current list of accounts, and re-emits on any change. */
    fun observeAccounts(): Flow<List<Account>>

    /**
     * Re-fetches the JMAP session for [accountId] and returns the set of
     * capability URNs supported by that account (from [JmapAccount.accountCapabilities]).
     * Returns null if credentials are unavailable or the request fails.
     *
     * Common values: [JmapCapability.MAIL], [JmapCapability.SUBMISSION], [JmapCapability.CONTACTS].
     */
    suspend fun getCapabilities(accountId: String): Set<String>?

    /**
     * Discovers the JMAP session at [baseUrl]/.well-known/jmap, authenticates with [username]/[password],
     * persists the account row and credentials, and returns the new [Account].
     * [baseUrl] must include scheme and port, e.g. "https://mail.example.com" or "http://localhost:8080".
     */
    suspend fun addAccount(
        baseUrl: String,
        username: String,
        password: String,
    ): Result<Account>

    /**
     * Stores an IMAP+SMTP account locally (no JMAP discovery).
     * Creates an account row with empty JMAP fields and an imap_config row.
     */
    suspend fun addImapSmtpAccount(
        displayName: String,
        username: String,
        password: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: String,
        smtpHost: String,
        smtpPort: Int,
        smtpSecurity: String,
    ): Result<Account>

    /**
     * Tests IMAP and SMTP connectivity with the given credentials without persisting anything.
     * Returns [Result.success] if both connections succeed, [Result.failure] with the error otherwise.
     */
    suspend fun checkImapSmtpConnection(
        username: String,
        password: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: String,
        smtpHost: String,
        smtpPort: Int,
        smtpSecurity: String,
    ): Result<Unit>

    /**
     * Removes the account and all its data (mailboxes, emails, state tokens)
     * via ON DELETE CASCADE. Also clears stored credentials.
     */
    suspend fun removeAccount(accountId: String)
}
