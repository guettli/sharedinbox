package de.sharedinbox.data.db

import android.content.Context
import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.driver.android.AndroidSqliteDriver

actual class DriverFactory actual constructor(private val context: Any) {
    actual fun createDriver(): SqlDriver =
        AndroidSqliteDriver(SharedInboxDatabase.Schema, context as Context, "sharedinbox.db")
}
