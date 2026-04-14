package de.sharedinbox.android

import android.app.Application
import androidx.work.Configuration
import androidx.work.WorkManager

class SharedInboxApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // Initialize WorkManager with default configuration.
        // Koin is not started here — the Compose UI uses KoinApplication{} from App().
        // SyncWorker instantiates its own repository instances from DriverFactory directly.
        WorkManager.initialize(
            this,
            Configuration.Builder().build(),
        )
    }
}
