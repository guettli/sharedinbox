package de.sharedinbox.data.db

import app.cash.sqldelight.db.SqlDriver

/**
 * Platform-specific SQLite driver factory.
 *
 * [context] carries an Android [android.content.Context] on Android; ignored on other platforms.
 * Pass [Unit] on JVM/iOS.
 */
expect class DriverFactory(context: Any) {
    fun createDriver(): SqlDriver
}
