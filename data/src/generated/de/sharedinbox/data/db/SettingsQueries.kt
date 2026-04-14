package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long

public class SettingsQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectSyncSettings(mapper: (
    mobile_days: Long,
    mobile_mb_limit: Long,
    wifi_days: Long,
    wifi_mb_limit: Long,
  ) -> T): Query<T> = Query(576_083_773, arrayOf("sync_settings"), driver, "Settings.sq", "selectSyncSettings", """
  |SELECT mobile_days, mobile_mb_limit, wifi_days, wifi_mb_limit
  |FROM sync_settings WHERE id = 1
  """.trimMargin()) { cursor ->
    mapper(
      cursor.getLong(0)!!,
      cursor.getLong(1)!!,
      cursor.getLong(2)!!,
      cursor.getLong(3)!!
    )
  }

  public fun selectSyncSettings(): Query<SelectSyncSettings> = selectSyncSettings(::SelectSyncSettings)

  /**
   * @return The number of rows updated.
   */
  public fun upsertSyncSettings(
    mobile_days: Long,
    mobile_mb_limit: Long,
    wifi_days: Long,
    wifi_mb_limit: Long,
  ): QueryResult<Long> {
    val result = driver.execute(-1_983_740_176, """
        |INSERT OR REPLACE INTO sync_settings (id, mobile_days, mobile_mb_limit, wifi_days, wifi_mb_limit)
        |VALUES (1, ?, ?, ?, ?)
        """.trimMargin(), 4) {
          var parameterIndex = 0
          bindLong(parameterIndex++, mobile_days)
          bindLong(parameterIndex++, mobile_mb_limit)
          bindLong(parameterIndex++, wifi_days)
          bindLong(parameterIndex++, wifi_mb_limit)
        }
    notifyQueries(-1_983_740_176) { emit ->
      emit("sync_settings")
    }
    return result
  }
}
