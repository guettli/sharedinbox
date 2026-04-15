package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class AccountQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectAllAccounts(mapper: (
    id: String,
    display_name: String,
    base_url: String,
    username: String,
    jmap_account_id: String,
    api_url: String,
    upload_url: String,
    download_url: String,
    event_source_url: String,
    added_at: Long,
  ) -> T): Query<T> = Query(-265_434_430, arrayOf("account"), driver, "Account.sq", "selectAllAccounts", "SELECT account.id, account.display_name, account.base_url, account.username, account.jmap_account_id, account.api_url, account.upload_url, account.download_url, account.event_source_url, account.added_at FROM account ORDER BY added_at") { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4)!!,
      cursor.getString(5)!!,
      cursor.getString(6)!!,
      cursor.getString(7)!!,
      cursor.getString(8)!!,
      cursor.getLong(9)!!
    )
  }

  public fun selectAllAccounts(): Query<Account> = selectAllAccounts(::Account)

  public fun <T : Any> selectAccount(id: String, mapper: (
    id: String,
    display_name: String,
    base_url: String,
    username: String,
    jmap_account_id: String,
    api_url: String,
    upload_url: String,
    download_url: String,
    event_source_url: String,
    added_at: Long,
  ) -> T): Query<T> = SelectAccountQuery(id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4)!!,
      cursor.getString(5)!!,
      cursor.getString(6)!!,
      cursor.getString(7)!!,
      cursor.getString(8)!!,
      cursor.getLong(9)!!
    )
  }

  public fun selectAccount(id: String): Query<Account> = selectAccount(id, ::Account)

  /**
   * @return The number of rows updated.
   */
  public fun insertAccount(
    id: String,
    display_name: String,
    base_url: String,
    username: String,
    jmap_account_id: String,
    api_url: String,
    upload_url: String,
    download_url: String,
    event_source_url: String,
    added_at: Long,
  ): QueryResult<Long> {
    val result = driver.execute(-1_232_198_293, """INSERT OR REPLACE INTO account VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", 10) {
          var parameterIndex = 0
          bindString(parameterIndex++, id)
          bindString(parameterIndex++, display_name)
          bindString(parameterIndex++, base_url)
          bindString(parameterIndex++, username)
          bindString(parameterIndex++, jmap_account_id)
          bindString(parameterIndex++, api_url)
          bindString(parameterIndex++, upload_url)
          bindString(parameterIndex++, download_url)
          bindString(parameterIndex++, event_source_url)
          bindLong(parameterIndex++, added_at)
        }
    notifyQueries(-1_232_198_293) { emit ->
      emit("account")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteAccount(id: String): QueryResult<Long> {
    val result = driver.execute(-925_462_983, """DELETE FROM account WHERE id = ?""", 1) {
          var parameterIndex = 0
          bindString(parameterIndex++, id)
        }
    notifyQueries(-925_462_983) { emit ->
      emit("account")
      emit("email_body")
      emit("email_header")
      emit("imap_config")
      emit("mailbox")
      emit("recent_address")
      emit("state_token")
      emit("sync_log")
    }
    return result
  }

  private inner class SelectAccountQuery<out T : Any>(
    public val id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("account", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("account", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(2_765_256, """SELECT account.id, account.display_name, account.base_url, account.username, account.jmap_account_id, account.api_url, account.upload_url, account.download_url, account.event_source_url, account.added_at FROM account WHERE id = ?""", mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, id)
    }

    override fun toString(): String = "Account.sq:selectAccount"
  }
}
