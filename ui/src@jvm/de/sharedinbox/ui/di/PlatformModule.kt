package de.sharedinbox.ui.di

import de.sharedinbox.core.platform.AttachmentOpener
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.DriverFactory
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.platform.JvmAttachmentOpener
import de.sharedinbox.data.store.FileTokenStore
import org.koin.core.module.Module
import org.koin.dsl.module

actual fun platformModule(@Suppress("UNUSED_PARAMETER") context: Any): Module = module {
    single { DriverFactory(Unit).createDriver() }
    single { SharedInboxDatabase(get()) }
    single<TokenStore> { FileTokenStore() }
    single<AttachmentOpener> { JvmAttachmentOpener() }
}
