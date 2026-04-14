package de.sharedinbox.data.db

import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import java.io.File

actual class DriverFactory actual constructor(
    @Suppress("UNUSED_PARAMETER") context: Any,
) {
    actual fun createDriver(): SqlDriver {
        val dbFile = File(System.getProperty("user.home"), ".sharedinbox/sharedinbox.db")
        dbFile.parentFile?.mkdirs()
        val isNew = !dbFile.exists()
        val driver = JdbcSqliteDriver("jdbc:sqlite:${dbFile.absolutePath}")
        driver.execute(null, "PRAGMA foreign_keys = ON", 0)
        if (isNew) {
            SharedInboxDatabase.Schema.create(driver)
        }
        return driver
    }
}
