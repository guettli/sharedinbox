package de.sharedinbox.ui.di

import de.sharedinbox.core.jmap.mail.MailboxRole
import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.platform.AttachmentOpener
import de.sharedinbox.core.repository.AccountRepository
import de.sharedinbox.core.repository.EmailRepository
import de.sharedinbox.core.repository.ImageTrustRepository
import de.sharedinbox.core.repository.MailboxRepository
import de.sharedinbox.core.repository.RecentAddressRepository
import de.sharedinbox.core.repository.SessionRepository
import de.sharedinbox.core.repository.SieveRepository
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.repository.SyncSettingsRepository
import de.sharedinbox.data.repository.AccountRepositoryImpl
import de.sharedinbox.data.repository.EmailRepositoryImpl
import de.sharedinbox.data.repository.ImageTrustRepositoryImpl
import de.sharedinbox.data.repository.JmapContactBookRepository
import de.sharedinbox.data.repository.MailboxRepositoryImpl
import de.sharedinbox.data.repository.RecentAddressRepositoryImpl
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.repository.SieveRepositoryImpl
import de.sharedinbox.data.repository.SyncLogRepositoryImpl
import de.sharedinbox.data.repository.SyncSettingsRepositoryImpl
import de.sharedinbox.data.sync.AccountSyncManager
import de.sharedinbox.ui.viewmodel.AccountListViewModel
import de.sharedinbox.ui.viewmodel.AddAccountViewModel
import de.sharedinbox.ui.viewmodel.ComposeViewModel
import de.sharedinbox.ui.viewmodel.EmailDetailViewModel
import de.sharedinbox.ui.viewmodel.EmailListViewModel
import de.sharedinbox.ui.viewmodel.MailboxListViewModel
import de.sharedinbox.ui.viewmodel.SearchViewModel
import de.sharedinbox.ui.viewmodel.SieveFilterViewModel
import de.sharedinbox.ui.viewmodel.SyncLogViewModel
import de.sharedinbox.ui.viewmodel.SyncSettingsViewModel
import kotlinx.coroutines.flow.first
import org.koin.core.module.dsl.viewModelOf
import org.koin.dsl.module

/**
 * Common Koin modules.
 *
 * Each platform entry point provides a [platformModule] that must bind:
 *   - [app.cash.sqldelight.db.SqlDriver]  — platform SQLite driver
 *   - [de.sharedinbox.data.db.SharedInboxDatabase] — created from the driver
 *   - [de.sharedinbox.core.repository.TokenStore] — credential storage
 */
val dataModule =
    module {
        single<SessionRepository> { SessionRepositoryImpl() }
        single<SyncLogRepository> { SyncLogRepositoryImpl(get()) }
        single<AccountRepository> { AccountRepositoryImpl(get(), get(), get()) }
        single<MailboxRepository> { MailboxRepositoryImpl(get(), get(), get()) }
        single<RecentAddressRepository> { RecentAddressRepositoryImpl(get()) }
        single<SyncSettingsRepository> { SyncSettingsRepositoryImpl(get()) }
        single<ImageTrustRepository> { ImageTrustRepositoryImpl(get()) }
        single { JmapContactBookRepository(get(), get()) }
        single<SieveRepository> { SieveRepositoryImpl(get(), get()) }
        single<EmailRepository> { EmailRepositoryImpl(get(), get(), get(), get(), get(), get(), get()) }

        single {
            val mailboxRepo: MailboxRepository = get()
            val emailRepo: EmailRepository = get()
            AccountSyncManager(
                db = get(),
                tokenStore = get(),
                onStateChange = { accountId, changedTypes ->
                    if ("Mailbox" in changedTypes) {
                        mailboxRepo.syncMailboxes(accountId)
                    }
                    if ("Email" in changedTypes) {
                        val inboxId =
                            mailboxRepo
                                .observeMailboxes(accountId)
                                .first()
                                .firstOrNull { it.role == MailboxRole.INBOX }
                                ?.id
                        if (inboxId != null) {
                            emailRepo.syncEmails(accountId, inboxId)
                        }
                    }
                },
            )
        }
    }

val uiModule =
    module {
        viewModelOf(::AccountListViewModel)
        viewModelOf(::AddAccountViewModel)
        viewModelOf(::MailboxListViewModel)
        viewModelOf(::EmailListViewModel)
        viewModelOf(::EmailDetailViewModel)
        viewModelOf(::ComposeViewModel)
        viewModelOf(::SyncLogViewModel)
        viewModelOf(::SyncSettingsViewModel)
        viewModelOf(::SearchViewModel)
        viewModelOf(::SieveFilterViewModel)
    }
