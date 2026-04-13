package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class StateTokenQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun selectStateToken(account_id: String, type_name: String): Query<String> = SelectStateTokenQuery(account_id, type_name) { cursor ->
    cursor.getString(0)!!
  }

  /**
   * @return The number of rows updated.
   */
  public fun upsertStateToken(
    account_id: String,
    type_name: String,
    state: String,
  ): QueryResult<Long> {
    val result = driver.execute(1_013_263_935, """INSERT OR REPLACE INTO state_token VALUES (?, ?, ?)""", 3) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, type_name)
          bindString(parameterIndex++, state)
        }
    notifyQueries(1_013_263_935) { emit ->
      emit("state_token")
    }
    return result
  }

  private inner class SelectStateTokenQuery<out T : Any>(
    public val account_id: String,
    public val type_name: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("state_token", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("state_token", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-61_166_132, """SELECT state FROM state_token WHERE account_id = ? AND type_name = ?""", mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, type_name)
    }

    override fun toString(): String = "StateToken.sq:selectStateToken"
  }
}
