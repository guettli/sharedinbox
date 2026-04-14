package de.sharedinbox.core.repository

import de.sharedinbox.core.jmap.JmapSession

interface SessionRepository {
    /**
     * Fetches and parses the JMAP session resource at GET [baseUrl]/.well-known/jmap.
     * [baseUrl] must include scheme and any non-standard port, e.g. "http://localhost:8080".
     */
    suspend fun discover(
        baseUrl: String,
        username: String,
        password: String,
    ): Result<JmapSession>

    /** Returns the cached session for [accountId], or null if not yet discovered. */
    suspend fun getSession(accountId: String): JmapSession?
}
