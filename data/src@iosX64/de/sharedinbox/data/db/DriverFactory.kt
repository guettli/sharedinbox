package de.sharedinbox.data.db

import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.driver.native.NativeSqliteDriver

actual class DriverFactory actual constructor(@Suppress("UNUSED_PARAMETER") context: Any) {
    actual fun createDriver(): SqlDriver =
        NativeSqliteDriver(SharedInboxDatabase.Schema, "sharedinbox.db")
}
