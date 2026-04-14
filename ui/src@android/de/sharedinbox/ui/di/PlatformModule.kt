package de.sharedinbox.ui.di

import android.content.Context
import de.sharedinbox.core.platform.AttachmentOpener
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.DriverFactory
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.platform.AndroidAttachmentOpener
import de.sharedinbox.data.store.AndroidTokenStore
import org.koin.core.module.Module
import org.koin.dsl.module

actual fun platformModule(context: Any): Module = module {
    single { DriverFactory(context as Context).createDriver() }
    single { SharedInboxDatabase(get()) }
    single<TokenStore> { AndroidTokenStore(context as Context) }
    single<AttachmentOpener> { AndroidAttachmentOpener() }
}
