package de.sharedinbox.data.repository

import de.sharedinbox.core.jmap.JmapSession
import de.sharedinbox.core.repository.SessionRepository
import de.sharedinbox.data.http.createHttpClient
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*

class SessionRepositoryImpl : SessionRepository {
    // Phase 3: cache sessions keyed by accountId in DB (state_token table)
    private val sessionCache = mutableMapOf<String, JmapSession>()

    override suspend fun discover(
        baseUrl: String,
        username: String,
        password: String,
    ): Result<JmapSession> =
        runCatching {
            val client = createHttpClient(username, password)
            try {
                client.get("$baseUrl/.well-known/jmap").body<JmapSession>()
            } finally {
                client.close()
            }
        }

    override suspend fun getSession(accountId: String): JmapSession? = sessionCache[accountId]
}
