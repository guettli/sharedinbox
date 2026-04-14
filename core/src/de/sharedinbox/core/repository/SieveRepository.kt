package de.sharedinbox.core.repository

/**
 * Manages Sieve mail-filtering scripts for a single account.
 *
 * First version: exposes the active script as plain text and allows saving it back.
 * Syntax validation is delegated to the server — [saveScript] returns a non-null
 * error message when the server rejects the script (e.g. syntax error).
 */
interface SieveRepository {
    /**
     * Returns the content of the first active Sieve script, or an empty string
     * when no scripts exist on the server.
     */
    suspend fun loadScript(accountId: String): String

    /**
     * Uploads [content] as a Sieve script and activates it.
     *
     * Returns null on success, or an error message from the server on failure
     * (e.g. "invalidScript: Parse error at line 3").
     */
    suspend fun saveScript(
        accountId: String,
        content: String,
    ): String?
}
