package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class RecentAddressQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectRecentByAccount(account_id: String, mapper: (
    email: String,
    name: String?,
    account_id: String,
    last_used: Long,
    use_count: Long,
  ) -> T): Query<T> = SelectRecentByAccountQuery(account_id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1),
      cursor.getString(2)!!,
      cursor.getLong(3)!!,
      cursor.getLong(4)!!
    )
  }

  public fun selectRecentByAccount(account_id: String): Query<Recent_address> = selectRecentByAccount(account_id, ::Recent_address)

  public fun <T : Any> searchByAccount(
    account_id: String,
    `value`: String,
    value_: String,
    mapper: (
      email: String,
      name: String?,
      account_id: String,
      last_used: Long,
      use_count: Long,
    ) -> T,
  ): Query<T> = SearchByAccountQuery(account_id, value, value_) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1),
      cursor.getString(2)!!,
      cursor.getLong(3)!!,
      cursor.getLong(4)!!
    )
  }

  public fun searchByAccount(
    account_id: String,
    value_: String,
    value__: String,
  ): Query<Recent_address> = searchByAccount(account_id, value_, value__, ::Recent_address)

  /**
   * @return The number of rows updated.
   */
  public fun insertOrIgnoreAddress(
    email: String,
    name: String?,
    account_id: String,
    last_used: Long,
  ): QueryResult<Long> {
    val result = driver.execute(-104_338_703, """
        |INSERT OR IGNORE INTO recent_address(email, name, account_id, last_used, use_count)
        |VALUES (?, ?, ?, ?, 0)
        """.trimMargin(), 4) {
          var parameterIndex = 0
          bindString(parameterIndex++, email)
          bindString(parameterIndex++, name)
          bindString(parameterIndex++, account_id)
          bindLong(parameterIndex++, last_used)
        }
    notifyQueries(-104_338_703) { emit ->
      emit("recent_address")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun updateAddressUsage(
    name: String?,
    last_used: Long,
    email: String,
    account_id: String,
  ): QueryResult<Long> {
    val result = driver.execute(-1_851_449_589, """
        |UPDATE recent_address
        |SET name      = ?,
        |    last_used = ?,
        |    use_count = use_count + 1
        |WHERE email = ? AND account_id = ?
        """.trimMargin(), 4) {
          var parameterIndex = 0
          bindString(parameterIndex++, name)
          bindLong(parameterIndex++, last_used)
          bindString(parameterIndex++, email)
          bindString(parameterIndex++, account_id)
        }
    notifyQueries(-1_851_449_589) { emit ->
      emit("recent_address")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteByAccount(account_id: String): QueryResult<Long> {
    val result = driver.execute(1_128_424_182, """DELETE FROM recent_address WHERE account_id = ?""", 1) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
        }
    notifyQueries(1_128_424_182) { emit ->
      emit("recent_address")
    }
    return result
  }

  private inner class SelectRecentByAccountQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("recent_address", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("recent_address", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-853_770_390, """
    |SELECT recent_address.email, recent_address.name, recent_address.account_id, recent_address.last_used, recent_address.use_count FROM recent_address
    |WHERE account_id = ?
    |ORDER BY last_used DESC
    |LIMIT 50
    """.trimMargin(), mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "RecentAddress.sq:selectRecentByAccount"
  }

  private inner class SearchByAccountQuery<out T : Any>(
    public val account_id: String,
    public val `value`: String,
    public val value_: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("recent_address", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("recent_address", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-1_523_699_815, """
    |SELECT recent_address.email, recent_address.name, recent_address.account_id, recent_address.last_used, recent_address.use_count FROM recent_address
    |WHERE account_id = ?
    |  AND (
    |       email LIKE '%' || ? || '%' ESCAPE '\'
    |    OR name  LIKE '%' || ? || '%' ESCAPE '\'
    |  )
    |ORDER BY use_count DESC, last_used DESC
    |LIMIT 20
    """.trimMargin(), mapper, 3) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, value)
      bindString(parameterIndex++, value_)
    }

    override fun toString(): String = "RecentAddress.sq:searchByAccount"
  }
}
