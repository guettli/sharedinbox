package de.sharedinbox.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailAddress
import de.sharedinbox.core.jmap.mail.EmailBodyPart
import de.sharedinbox.core.jmap.mail.EmailBodyValue
import de.sharedinbox.core.jmap.mail.EmailDraft
import de.sharedinbox.core.jmap.mail.MailboxRole
import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.network.NetworkType
import de.sharedinbox.core.repository.EmailRepository
import de.sharedinbox.core.repository.MailboxRepository
import de.sharedinbox.core.repository.RecentAddressRepository
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.repository.SyncSettingsRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import kotlin.time.Clock
import kotlin.time.Duration.Companion.days
import kotlin.time.Instant

class EmailRepositoryImpl(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
    private val syncLog: SyncLogRepository,
    private val mailboxRepo: MailboxRepository,
    private val recentAddresses: RecentAddressRepository,
    private val syncSettings: SyncSettingsRepository,
    private val networkMonitor: NetworkMonitor,
) : EmailRepository {
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observe ───────────────────────────────────────────────────────────────

    override fun observeEmails(
        accountId: String,
        mailboxId: String,
    ): Flow<List<Email>> =
        db.emailHeaderQueries
            .selectEmailsByMailbox(accountId, mailboxId)
            .asFlow()
            .mapToList(Dispatchers.IO)
            .map { rows -> rows.map { it.toDomain() } }

    // ── Sync (Phase 6) ────────────────────────────────────────────────────────

    override suspend fun syncEmails(
        accountId: String,
        mailboxId: String,
    ): Result<Unit> =
        runCatching {
            try {
                withApiClient(accountId) { apiClient, account ->
                    val sinceState =
                        db.stateTokenQueries
                            .selectStateToken(accountId, "Email")
                            .executeAsOneOrNull()
                    if (sinceState == null) {
                        fullSyncEmails(accountId, account.jmap_account_id, mailboxId, apiClient)
                    } else {
                        incrementalSyncEmails(accountId, account.jmap_account_id, apiClient, sinceState)
                    }
                }
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.SERVER_TO_DB,
                    operation = "sync_emails",
                    status = SyncStatus.SUCCESS,
                )
            } catch (e: Exception) {
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.SERVER_TO_DB,
                    operation = "sync_emails",
                    status = SyncStatus.ERROR,
                    detail = e.message,
                )
                throw e
            }
        }

    private suspend fun fullSyncEmails(
        accountId: String,
        jmapAccountId: String,
        mailboxId: String,
        apiClient: JmapApiClient,
    ) {
        val settings = syncSettings.get()
        val days =
            when (networkMonitor.currentNetworkType()) {
                NetworkType.MOBILE -> settings.mobileDays
                NetworkType.WIFI_OR_UNMETERED -> settings.wifiDays
            }
        val after = Clock.System.now() - days.days
        val queryResult = apiClient.queryEmails(jmapAccountId, mailboxId, after = after)
        if (queryResult.ids.isEmpty()) {
            // No emails — save initial state if provided via a zero-ids Email/get
            val getResult = apiClient.getEmailHeaders(jmapAccountId, emptyList())
            db.stateTokenQueries.upsertStateToken(accountId, "Email", getResult.state)
            return
        }
        val getResult = apiClient.getEmailHeaders(jmapAccountId, queryResult.ids)
        db.emailHeaderQueries.transaction {
            getResult.list.forEach { upsertEmailHeader(accountId, it) }
            db.stateTokenQueries.upsertStateToken(accountId, "Email", getResult.state)
        }
    }

    private suspend fun incrementalSyncEmails(
        accountId: String,
        jmapAccountId: String,
        apiClient: JmapApiClient,
        sinceState: String,
    ) {
        val changes = apiClient.getEmailChanges(jmapAccountId, sinceState)
        val toFetch = (changes.created + changes.updated).distinct()

        val fetched =
            if (toFetch.isNotEmpty()) {
                apiClient.getEmailHeaders(jmapAccountId, toFetch).list
            } else {
                emptyList()
            }

        db.emailHeaderQueries.transaction {
            fetched.forEach { upsertEmailHeader(accountId, it) }
            changes.destroyed.forEach {
                db.emailHeaderQueries.deleteEmailHeader(accountId, it)
                db.emailBodyQueries.deleteEmailBody(accountId, it)
            }
            db.stateTokenQueries.upsertStateToken(accountId, "Email", changes.newState)
        }

        if (changes.hasMoreChanges) {
            incrementalSyncEmails(accountId, jmapAccountId, apiClient, changes.newState)
        }
    }

    // ── Body fetch (Phase 7) ──────────────────────────────────────────────────

    override suspend fun getEmail(
        accountId: String,
        emailId: String,
    ): Result<Email> =
        runCatching {
            val header =
                db.emailHeaderQueries
                    .selectEmailById(accountId, emailId)
                    .executeAsOneOrNull()
                    ?: error("Email $emailId not found in local DB — sync first")

            val cachedBody =
                db.emailBodyQueries
                    .selectEmailBody(accountId, emailId)
                    .executeAsOneOrNull()

            if (cachedBody != null) {
                return@runCatching header.toDomain().withBody(cachedBody)
            }

            // Fetch body from server and cache it
            withApiClient(accountId) { apiClient, account ->
                val bodyOnly = apiClient.getEmailBody(account.jmap_account_id, emailId)
                val textContent =
                    bodyOnly.textBody
                        .firstOrNull()
                        ?.partId
                        ?.let { bodyOnly.bodyValues[it]?.value }
                val htmlContent =
                    bodyOnly.htmlBody
                        .firstOrNull()
                        ?.partId
                        ?.let { bodyOnly.bodyValues[it]?.value }
                db.emailBodyQueries.upsertEmailBody(
                    email_id = emailId,
                    account_id = accountId,
                    text_body = textContent,
                    html_body = htmlContent,
                )
                header.toDomain().withBody(textContent, htmlContent)
            }
        }

    // ── Mutations (Phase 9) ───────────────────────────────────────────────────

    override suspend fun setKeyword(
        accountId: String,
        emailId: String,
        keyword: String,
        set: Boolean,
    ): Result<Unit> =
        runCatching {
            withApiClient(accountId) { apiClient, account ->
                val patch =
                    buildJsonObject {
                        if (set) {
                            put("keywords/$keyword", true)
                        } else {
                            put("keywords/$keyword", JsonNull)
                        }
                    }
                val result =
                    apiClient.emailSet(
                        account.jmap_account_id,
                        buildJsonObject {
                            put("update", buildJsonObject { put(emailId, patch) })
                        },
                    )
                if (result.notUpdated.isNotEmpty()) {
                    val detail =
                        result.notUpdated.entries.joinToString { (_, e) ->
                            "${e.type}: ${e.description ?: "no description"}"
                        }
                    syncLog.log(
                        accountId = accountId,
                        direction = SyncDirection.DB_TO_SERVER,
                        operation = "set_keyword",
                        status = SyncStatus.CONFLICT,
                        detail = "emailId=$emailId keyword=$keyword set=$set — $detail",
                    )
                    error("setKeyword failed for $emailId: ${result.notUpdated}")
                }
                // Update local DB
                val header =
                    db.emailHeaderQueries
                        .selectEmailById(accountId, emailId)
                        .executeAsOneOrNull() ?: return@withApiClient
                val current = decodeKeywords(header.keywords).toMutableSet()
                if (set) current.add(keyword) else current.remove(keyword)
                db.emailHeaderQueries.updateEmailKeywords(
                    keywords = json.encodeToString(current.toList()),
                    account_id = accountId,
                    id = emailId,
                )
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.DB_TO_SERVER,
                    operation = "set_keyword",
                    status = SyncStatus.SUCCESS,
                    detail = "emailId=$emailId keyword=$keyword set=$set",
                )
            }
        }

    override suspend fun moveEmail(
        accountId: String,
        emailId: String,
        toMailboxId: String,
    ): Result<Unit> =
        runCatching {
            withApiClient(accountId) { apiClient, account ->
                val header =
                    db.emailHeaderQueries
                        .selectEmailById(accountId, emailId)
                        .executeAsOneOrNull() ?: error("Email $emailId not found")
                val fromMailboxId = header.mailbox_id
                val patch =
                    buildJsonObject {
                        put("mailboxIds/$toMailboxId", true)
                        put("mailboxIds/$fromMailboxId", JsonNull)
                    }
                val result =
                    apiClient.emailSet(
                        account.jmap_account_id,
                        buildJsonObject {
                            put("update", buildJsonObject { put(emailId, patch) })
                        },
                    )
                if (result.notUpdated.isNotEmpty()) {
                    val detail =
                        result.notUpdated.entries.joinToString { (_, e) ->
                            "${e.type}: ${e.description ?: "no description"}"
                        }
                    syncLog.log(
                        accountId = accountId,
                        direction = SyncDirection.DB_TO_SERVER,
                        operation = "move_email",
                        status = SyncStatus.CONFLICT,
                        detail = "emailId=$emailId toMailboxId=$toMailboxId — $detail",
                    )
                    error("moveEmail failed for $emailId: ${result.notUpdated}")
                }
                db.emailHeaderQueries.updateEmailMailboxId(
                    mailbox_id = toMailboxId,
                    account_id = accountId,
                    id = emailId,
                )
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.DB_TO_SERVER,
                    operation = "move_email",
                    status = SyncStatus.SUCCESS,
                    detail = "emailId=$emailId toMailboxId=$toMailboxId",
                )
            }
        }

    override suspend fun deleteEmail(
        accountId: String,
        emailId: String,
    ): Result<Unit> =
        runCatching {
            val header =
                db.emailHeaderQueries
                    .selectEmailById(accountId, emailId)
                    .executeAsOneOrNull() ?: error("Email $emailId not found")
            val trashId = getOrCreateMailboxId(accountId, MailboxRole.TRASH, "Trash")

            if (header.mailbox_id != trashId) {
                // Move to trash first
                moveEmail(accountId, emailId, trashId).getOrThrow()
            } else {
                // Already in trash — permanently delete
                withApiClient(accountId) { apiClient, account ->
                    val result =
                        apiClient.emailSet(
                            account.jmap_account_id,
                            buildJsonObject {
                                put("destroy", buildJsonArray { add(emailId) })
                            },
                        )
                    if (result.notDestroyed.isNotEmpty()) {
                        val detail =
                            result.notDestroyed.entries.joinToString { (_, e) ->
                                "${e.type}: ${e.description ?: "no description"}"
                            }
                        syncLog.log(
                            accountId = accountId,
                            direction = SyncDirection.DB_TO_SERVER,
                            operation = "delete_email",
                            status = SyncStatus.CONFLICT,
                            detail = "emailId=$emailId — $detail",
                        )
                        error("deleteEmail failed for $emailId: ${result.notDestroyed}")
                    }
                    db.emailHeaderQueries.deleteEmailHeader(accountId, emailId)
                    db.emailBodyQueries.deleteEmailBody(accountId, emailId)
                    syncLog.log(
                        accountId = accountId,
                        direction = SyncDirection.DB_TO_SERVER,
                        operation = "delete_email",
                        status = SyncStatus.SUCCESS,
                        detail = "emailId=$emailId",
                    )
                }
            }
        }

    override suspend fun sendEmail(
        accountId: String,
        draft: EmailDraft,
    ): Result<Unit> =
        runCatching {
            withApiClient(accountId) { apiClient, account ->
                // Prefer JMAP submission (requires submission capability); fall back to
                // placing the message directly in the Sent folder when no identity is available.
                val identity =
                    runCatching {
                        apiClient
                            .getIdentities(account.jmap_account_id)
                            .list
                            .firstOrNull { !it.email.isNullOrBlank() }
                    }.getOrNull()

                val mailboxes = db.mailboxQueries.selectMailboxesByAccount(accountId).executeAsList()
                val draftsMailbox =
                    mailboxes.firstOrNull { it.role == "\$draft" || it.role == "drafts" }
                        ?: mailboxes.firstOrNull()
                        ?: error("No mailbox found for account $accountId — sync mailboxes first")

                if (identity != null) {
                    // Full JMAP submission path
                    val createResult =
                        apiClient.emailSet(
                            account.jmap_account_id,
                            buildJsonObject {
                                put(
                                    "create",
                                    buildJsonObject {
                                        put(
                                            "draft1",
                                            buildJsonObject {
                                                put("mailboxIds", buildJsonObject { put(draftsMailbox.id, true) })
                                                put(
                                                    "from",
                                                    json.encodeToJsonElement(
                                                        kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                        listOf(draft.from),
                                                    ),
                                                )
                                                put(
                                                    "to",
                                                    json.encodeToJsonElement(
                                                        kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                        draft.to,
                                                    ),
                                                )
                                                if (draft.cc.isNotEmpty()) {
                                                    put(
                                                        "cc",
                                                        json.encodeToJsonElement(
                                                            kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                            draft.cc,
                                                        ),
                                                    )
                                                }
                                                put("subject", draft.subject)
                                                put(
                                                    "bodyValues",
                                                    buildJsonObject {
                                                        put("body1", buildJsonObject { put("value", draft.textBody) })
                                                    },
                                                )
                                                put(
                                                    "textBody",
                                                    buildJsonArray {
                                                        add(
                                                            buildJsonObject {
                                                                put("partId", "body1")
                                                                put("type", "text/plain")
                                                            },
                                                        )
                                                    },
                                                )
                                                put("keywords", buildJsonObject { put("\$draft", true) })
                                            },
                                        )
                                    },
                                )
                            },
                        )
                    if (createResult.notCreated.isNotEmpty()) {
                        val detail =
                            createResult.notCreated.entries.joinToString { (_, e) ->
                                "${e.type}: ${e.description ?: "no description"}"
                            }
                        syncLog.log(
                            accountId = accountId,
                            direction = SyncDirection.DB_TO_SERVER,
                            operation = "send_email",
                            status = SyncStatus.CONFLICT,
                            detail = "create draft failed — $detail",
                        )
                        error("sendEmail create failed: ${createResult.notCreated}")
                    }
                    val emailId =
                        createResult.created["draft1"]
                            ?.get("id")
                            ?.let { (it as? JsonPrimitive)?.content }
                            ?: error("Server did not return created email ID")

                    val submissionResult =
                        apiClient.emailSubmissionSet(
                            account.jmap_account_id,
                            identity.id,
                            emailId,
                        )
                    if (submissionResult.notCreated.isNotEmpty()) {
                        val detail =
                            submissionResult.notCreated.entries.joinToString { (_, e) ->
                                "${e.type}: ${e.description ?: "no description"}"
                            }
                        syncLog.log(
                            accountId = accountId,
                            direction = SyncDirection.DB_TO_SERVER,
                            operation = "send_email",
                            status = SyncStatus.CONFLICT,
                            detail = "submission failed — $detail",
                        )
                        error("sendEmail submission failed: ${submissionResult.notCreated}")
                    }
                    syncLog.log(
                        accountId = accountId,
                        direction = SyncDirection.DB_TO_SERVER,
                        operation = "send_email",
                        status = SyncStatus.SUCCESS,
                    )
                    recordRecipients(accountId, draft)
                } else {
                    // Fallback: place message directly in Sent folder (no JMAP submission capability)
                    val sentMailbox =
                        mailboxes.firstOrNull { it.role == "sent" }
                            ?: draftsMailbox
                    val createResult =
                        apiClient.emailSet(
                            account.jmap_account_id,
                            buildJsonObject {
                                put(
                                    "create",
                                    buildJsonObject {
                                        put(
                                            "sent1",
                                            buildJsonObject {
                                                put("mailboxIds", buildJsonObject { put(sentMailbox.id, true) })
                                                put(
                                                    "from",
                                                    json.encodeToJsonElement(
                                                        kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                        listOf(draft.from),
                                                    ),
                                                )
                                                put(
                                                    "to",
                                                    json.encodeToJsonElement(
                                                        kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                        draft.to,
                                                    ),
                                                )
                                                if (draft.cc.isNotEmpty()) {
                                                    put(
                                                        "cc",
                                                        json.encodeToJsonElement(
                                                            kotlinx.serialization.serializer<List<EmailAddress>>(),
                                                            draft.cc,
                                                        ),
                                                    )
                                                }
                                                put("subject", draft.subject)
                                                put(
                                                    "bodyValues",
                                                    buildJsonObject {
                                                        put("body1", buildJsonObject { put("value", draft.textBody) })
                                                    },
                                                )
                                                put(
                                                    "textBody",
                                                    buildJsonArray {
                                                        add(
                                                            buildJsonObject {
                                                                put("partId", "body1")
                                                                put("type", "text/plain")
                                                            },
                                                        )
                                                    },
                                                )
                                                put("keywords", buildJsonObject { put("\$sent", true) })
                                            },
                                        )
                                    },
                                )
                            },
                        )
                    if (createResult.notCreated.isNotEmpty()) {
                        val detail =
                            createResult.notCreated.entries.joinToString { (_, e) ->
                                "${e.type}: ${e.description ?: "no description"}"
                            }
                        syncLog.log(
                            accountId = accountId,
                            direction = SyncDirection.DB_TO_SERVER,
                            operation = "send_email",
                            status = SyncStatus.CONFLICT,
                            detail = "fallback create failed — $detail",
                        )
                        error("sendEmail (fallback) create failed: ${createResult.notCreated}")
                    }
                    syncLog.log(
                        accountId = accountId,
                        direction = SyncDirection.DB_TO_SERVER,
                        operation = "send_email",
                        status = SyncStatus.SUCCESS,
                    )
                    recordRecipients(accountId, draft)
                }
            }
        }

    private suspend fun recordRecipients(
        accountId: String,
        draft: EmailDraft,
    ) {
        (draft.to + draft.cc).forEach { address ->
            recentAddresses.recordUsage(accountId, address)
        }
    }

    override suspend fun archiveEmail(
        accountId: String,
        emailId: String,
    ): Result<Unit> =
        runCatching {
            val archiveId = getOrCreateMailboxId(accountId, MailboxRole.ARCHIVE, "Archive")
            moveEmail(accountId, emailId, archiveId).getOrThrow()
        }

    override suspend fun markAsSpam(
        accountId: String,
        emailId: String,
    ): Result<Unit> =
        runCatching {
            val junkId = getOrCreateMailboxId(accountId, MailboxRole.SPAM, "Junk")
            moveEmail(accountId, emailId, junkId).getOrThrow()
        }

    // ── Search (DB-only) ──────────────────────────────────────────────────────

    override suspend fun searchEmails(
        accountId: String,
        query: String,
    ): Result<List<Email>> =
        runCatching {
            db.emailHeaderQueries
                .searchEmailHeaders(accountId, query, query, query)
                .executeAsList()
                .map { it.toDomain() }
        }

    // ── Attachments ───────────────────────────────────────────────────────────

    override suspend fun getAttachments(
        accountId: String,
        emailId: String,
    ): Result<List<EmailBodyPart>> =
        runCatching {
            withApiClient(accountId) { apiClient, account ->
                apiClient.getEmailAttachments(account.jmap_account_id, emailId)
            }
        }

    override suspend fun downloadBlob(
        accountId: String,
        blobId: String,
        mimeType: String,
    ): Result<ByteArray> =
        runCatching {
            withApiClient(accountId) { apiClient, account ->
                apiClient.downloadBlob(account.download_url, account.jmap_account_id, blobId, mimeType)
            }
        }

    // ── helpers ───────────────────────────────────────────────────────────────

    /**
     * Returns the ID of a mailbox with the given [role] in [accountId]'s local DB.
     * If no such mailbox is found, creates one with [folderName] on the server (which
     * also writes it to the local DB) and returns its ID.
     */
    private suspend fun getOrCreateMailboxId(
        accountId: String,
        role: String,
        folderName: String,
    ): String {
        db.mailboxQueries
            .selectMailboxesByAccount(accountId)
            .executeAsList()
            .firstOrNull { it.role == role }
            ?.let { return it.id }

        // Not found locally — create on server
        return mailboxRepo.createMailbox(accountId, folderName).getOrThrow().id
    }

    private suspend fun <T> withApiClient(
        accountId: String,
        block: suspend (JmapApiClient, de.sharedinbox.data.db.Account) -> T,
    ): T {
        val account =
            db.accountQueries.selectAccount(accountId).executeAsOneOrNull()
                ?: error("Account $accountId not found")
        val credentials =
            tokenStore.loadCredentials(accountId)
                ?: error("No credentials for account $accountId")
        val httpClient = createHttpClient(credentials.username, credentials.password)
        return try {
            block(JmapApiClient(account.api_url, httpClient), account)
        } finally {
            httpClient.close()
        }
    }

    private fun upsertEmailHeader(
        accountId: String,
        email: Email,
    ) {
        db.emailHeaderQueries.upsertEmailHeader(
            id = email.id,
            account_id = accountId,
            thread_id = email.threadId,
            mailbox_id = email.mailboxIds.keys.firstOrNull() ?: "",
            subject = email.subject,
            from_address = email.from?.let { json.encodeToString(it) },
            received_at = email.receivedAt.toEpochMilliseconds(),
            keywords = json.encodeToString(email.keywords.keys.toList()),
            has_attachment = if (email.hasAttachment) 1L else 0L,
            preview = email.preview,
            blob_id = email.blobId,
        )
    }

    private fun decodeKeywords(encoded: String): List<String> =
        if (encoded.isBlank() || encoded == "[]") {
            emptyList()
        } else {
            runCatching { json.decodeFromString<List<String>>(encoded) }.getOrDefault(emptyList())
        }

    private fun de.sharedinbox.data.db.Email_header.toDomain(): Email =
        Email(
            id = id,
            blobId = blob_id,
            threadId = thread_id,
            mailboxIds = mapOf(mailbox_id to true),
            keywords = decodeKeywords(keywords).associateWith { true },
            subject = subject,
            receivedAt = Instant.fromEpochMilliseconds(received_at),
            from =
                from_address?.let {
                    runCatching { json.decodeFromString<List<EmailAddress>>(it) }.getOrNull()
                },
            hasAttachment = has_attachment != 0L,
            preview = preview,
        )

    private fun Email.withBody(body: de.sharedinbox.data.db.Email_body): Email = withBody(body.text_body, body.html_body)

    private fun Email.withBody(
        textContent: String?,
        htmlContent: String?,
    ): Email =
        copy(
            bodyValues =
                buildMap {
                    textContent?.let { put("text1", EmailBodyValue(it)) }
                    htmlContent?.let { put("html1", EmailBodyValue(it)) }
                },
            textBody =
                if (textContent != null) {
                    listOf(EmailBodyPart(partId = "text1", type = "text/plain"))
                } else {
                    emptyList()
                },
            htmlBody =
                if (htmlContent != null) {
                    listOf(EmailBodyPart(partId = "html1", type = "text/html"))
                } else {
                    emptyList()
                },
        )
}
