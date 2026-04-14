package de.sharedinbox.ui.di

import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.platform.AttachmentOpener
import de.sharedinbox.core.repository.ContactBookRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.contacts.IosContactBookRepository
import de.sharedinbox.data.db.DriverFactory
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.network.IosNetworkMonitor
import de.sharedinbox.data.platform.IosAttachmentOpener
import de.sharedinbox.data.store.IosTokenStore
import org.koin.core.module.Module
import org.koin.dsl.module

actual fun platformModule(
    @Suppress("UNUSED_PARAMETER") context: Any,
): Module =
    module {
        single { DriverFactory(Unit).createDriver() }
        single { SharedInboxDatabase(get()) }
        single<TokenStore> { IosTokenStore() }
        single<AttachmentOpener> { IosAttachmentOpener() }
        single<NetworkMonitor> { IosNetworkMonitor() }
        single<ContactBookRepository> { IosContactBookRepository() }
    }
