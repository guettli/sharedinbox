package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class SyncLogQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectLogsByAccount(account_id: String, mapper: (
    id: Long,
    account_id: String,
    occurred_at: Long,
    direction: String,
    operation: String,
    status: String,
    detail: String?,
  ) -> T): Query<T> = SelectLogsByAccountQuery(account_id) { cursor ->
    mapper(
      cursor.getLong(0)!!,
      cursor.getString(1)!!,
      cursor.getLong(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4)!!,
      cursor.getString(5)!!,
      cursor.getString(6)
    )
  }

  public fun selectLogsByAccount(account_id: String): Query<Sync_log> = selectLogsByAccount(account_id, ::Sync_log)

  public fun <T : Any> lastSuccessfulSync(account_id: String, mapper: (MAX: Long?) -> T): Query<T> = LastSuccessfulSyncQuery(account_id) { cursor ->
    mapper(
      cursor.getLong(0)
    )
  }

  public fun lastSuccessfulSync(account_id: String): Query<LastSuccessfulSync> = lastSuccessfulSync(account_id, ::LastSuccessfulSync)

  public fun <T : Any> lastErrorEntry(account_id: String, mapper: (
    id: Long,
    account_id: String,
    occurred_at: Long,
    direction: String,
    operation: String,
    status: String,
    detail: String?,
  ) -> T): Query<T> = LastErrorEntryQuery(account_id) { cursor ->
    mapper(
      cursor.getLong(0)!!,
      cursor.getString(1)!!,
      cursor.getLong(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4)!!,
      cursor.getString(5)!!,
      cursor.getString(6)
    )
  }

  public fun lastErrorEntry(account_id: String): Query<Sync_log> = lastErrorEntry(account_id, ::Sync_log)

  /**
   * @return The number of rows updated.
   */
  public fun insertSyncLog(
    account_id: String,
    occurred_at: Long,
    direction: String,
    operation: String,
    status: String,
    detail: String?,
  ): QueryResult<Long> {
    val result = driver.execute(-1_759_040_277, """
        |INSERT INTO sync_log(account_id, occurred_at, direction, operation, status, detail)
        |VALUES (?, ?, ?, ?, ?, ?)
        """.trimMargin(), 6) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindLong(parameterIndex++, occurred_at)
          bindString(parameterIndex++, direction)
          bindString(parameterIndex++, operation)
          bindString(parameterIndex++, status)
          bindString(parameterIndex++, detail)
        }
    notifyQueries(-1_759_040_277) { emit ->
      emit("sync_log")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteLogsByAccount(account_id: String): QueryResult<Long> {
    val result = driver.execute(1_298_589_687, """DELETE FROM sync_log WHERE account_id = ?""", 1) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
        }
    notifyQueries(1_298_589_687) { emit ->
      emit("sync_log")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteAllLogs(): QueryResult<Long> {
    val result = driver.execute(-622_179_840, """DELETE FROM sync_log""", 0)
    notifyQueries(-622_179_840) { emit ->
      emit("sync_log")
    }
    return result
  }

  private inner class SelectLogsByAccountQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("sync_log", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("sync_log", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-1_630_575_546, """
    |SELECT sync_log.id, sync_log.account_id, sync_log.occurred_at, sync_log.direction, sync_log.operation, sync_log.status, sync_log.detail FROM sync_log
    |WHERE account_id = ?
    |ORDER BY occurred_at DESC, id DESC
    |LIMIT 200
    """.trimMargin(), mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "SyncLog.sq:selectLogsByAccount"
  }

  private inner class LastSuccessfulSyncQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("sync_log", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("sync_log", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-278_436_304, """
    |SELECT MAX(occurred_at) FROM sync_log
    |WHERE account_id = ? AND status = 'success'
    """.trimMargin(), mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "SyncLog.sq:lastSuccessfulSync"
  }

  private inner class LastErrorEntryQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("sync_log", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("sync_log", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-14_189_915, """
    |SELECT sync_log.id, sync_log.account_id, sync_log.occurred_at, sync_log.direction, sync_log.operation, sync_log.status, sync_log.detail FROM sync_log
    |WHERE account_id = ? AND status = 'error'
    |ORDER BY occurred_at DESC
    |LIMIT 1
    """.trimMargin(), mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "SyncLog.sq:lastErrorEntry"
  }
}
