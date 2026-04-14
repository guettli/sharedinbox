package de.sharedinbox.android

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import de.sharedinbox.core.jmap.mail.MailboxRole
import de.sharedinbox.data.db.DriverFactory
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.repository.AccountRepositoryImpl
import de.sharedinbox.data.repository.EmailRepositoryImpl
import de.sharedinbox.data.repository.MailboxRepositoryImpl
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.repository.SyncLogRepositoryImpl
import de.sharedinbox.data.store.AndroidTokenStore
import kotlinx.coroutines.flow.first

/**
 * Background sync worker — runs every 15 minutes when the app is not in foreground.
 *
 * Creates its own repository instances from the on-disk database so that it doesn't
 * interfere with the Compose-scoped Koin context used by the UI.
 */
class SyncWorker(
    context: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(context, workerParams) {

    override suspend fun doWork(): Result {
        return try {
            val driver = DriverFactory(applicationContext).createDriver()
            val db = SharedInboxDatabase(driver)
            val tokenStore = AndroidTokenStore(applicationContext)
            val syncLogRepo = SyncLogRepositoryImpl(db)
            val accountRepo = AccountRepositoryImpl(db, tokenStore, SessionRepositoryImpl())
            val mailboxRepo = MailboxRepositoryImpl(db, tokenStore, syncLogRepo)
            val emailRepo = EmailRepositoryImpl(db, tokenStore, syncLogRepo, mailboxRepo)

            val accounts = accountRepo.observeAccounts().first()
            for (account in accounts) {
                mailboxRepo.syncMailboxes(account.id)

                val inboxId = mailboxRepo.observeMailboxes(account.id).first()
                    .firstOrNull { it.role == MailboxRole.INBOX }?.id ?: continue

                emailRepo.syncEmails(account.id, inboxId)
            }

            driver.close()
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }

    companion object {
        const val WORK_NAME = "sharedinbox_background_sync"
    }
}
