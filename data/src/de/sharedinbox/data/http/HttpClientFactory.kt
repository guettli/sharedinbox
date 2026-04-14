package de.sharedinbox.data.http

import io.ktor.client.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.auth.*
import io.ktor.client.plugins.auth.providers.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.logging.*
import io.ktor.client.plugins.sse.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.json.Json

/**
 * Creates a Ktor [HttpClient] pre-configured for JMAP API calls.
 *
 * The engine is auto-detected from the classpath (CIO on JVM, OkHttp on Android,
 * Darwin on iOS) — no expect/actual needed since each platform has exactly one
 * engine artifact.
 *
 * Credentials are sent on every request (no 401-challenge round-trip).
 */
fun createHttpClient(username: String, password: String): HttpClient = HttpClient {
    install(ContentNegotiation) {
        json(Json {
            ignoreUnknownKeys = true
            isLenient = true
        })
    }
    install(Auth) {
        basic {
            credentials { BasicAuthCredentials(username = username, password = password) }
            sendWithoutRequest { true }
        }
    }
    install(Logging) {
        logger = Logger.DEFAULT
        level = LogLevel.INFO
    }
    install(HttpRequestRetry) {
        retryOnServerErrors(maxRetries = 2)
        exponentialDelay()
    }
}

/** HTTP client with SSE plugin enabled — used by [AccountSyncManager]. */
fun createSseHttpClient(username: String, password: String): HttpClient = HttpClient {
    install(SSE)
    install(Auth) {
        basic {
            credentials { BasicAuthCredentials(username = username, password = password) }
            sendWithoutRequest { true }
        }
    }
    install(Logging) {
        logger = Logger.DEFAULT
        level = LogLevel.NONE
    }
}
