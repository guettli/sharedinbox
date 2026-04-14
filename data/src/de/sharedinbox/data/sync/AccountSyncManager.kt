package de.sharedinbox.data.sync

import de.sharedinbox.core.jmap.push.StateChange
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createSseHttpClient
import io.ktor.client.plugins.sse.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json

/**
 * Manages one SSE-driven sync loop per account.
 *
 * Usage:
 * ```
 * manager.startAccount(accountId)   // call after addAccount()
 * manager.stopAccount(accountId)    // call before removeAccount()
 * manager.stopAll()                 // on app exit
 * ```
 *
 * On each push notification the server sends a [StateChange]. The [onStateChange]
 * callback is invoked with the accountId and the set of changed type names
 * (e.g. `{"Mailbox", "Email"}`). The caller is responsible for triggering the
 * appropriate sync operations.
 */
class AccountSyncManager(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
    private val onStateChange: suspend (accountId: String, changedTypes: Set<String>) -> Unit,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val jobs = mutableMapOf<String, Job>()
    private val json = Json { ignoreUnknownKeys = true }

    fun startAccount(accountId: String) {
        if (accountId in jobs) return
        jobs[accountId] =
            scope.launch {
                runWithReconnect { streamEvents(accountId) }
            }
    }

    fun stopAccount(accountId: String) {
        jobs.remove(accountId)?.cancel()
    }

    fun stopAll() {
        jobs.values.forEach { it.cancel() }
        jobs.clear()
    }

    private suspend fun streamEvents(accountId: String) {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull() ?: return
        val credentials = tokenStore.loadCredentials(accountId) ?: return
        val httpClient = createSseHttpClient(credentials.username, credentials.password)
        try {
            val url = expandUrlTemplate(account.event_source_url)
            val session = httpClient.serverSentEventsSession(urlString = url)
            session.incoming.collect { event ->
                if (event.event == "state") {
                    val data = event.data ?: return@collect
                    val stateChange =
                        runCatching {
                            json.decodeFromString<StateChange>(data)
                        }.getOrNull() ?: return@collect
                    val changedTypes =
                        stateChange.changed[account.jmap_account_id]?.keys
                            ?: return@collect
                    onStateChange(accountId, changedTypes)
                }
            }
        } finally {
            httpClient.close()
        }
    }

    private fun expandUrlTemplate(template: String): String =
        template
            .replace("{types}", "*")
            .replace("{closeafter}", "no")
            .replace("{ping}", "60")

    /** Retries [block] with exponential back-off on failure; stops on cancellation. */
    private suspend fun runWithReconnect(block: suspend () -> Unit) {
        var delayMs = 1_000L
        while (true) {
            try {
                block()
            } catch (_: CancellationException) {
                return
            } catch (_: Exception) {
                delay(delayMs)
                delayMs = minOf(delayMs * 2, 60_000L)
            }
        }
    }
}
