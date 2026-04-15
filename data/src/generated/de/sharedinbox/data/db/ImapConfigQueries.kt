package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class ImapConfigQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectImapConfig(account_id: String, mapper: (
    account_id: String,
    imap_host: String,
    imap_port: Long,
    imap_security: String,
    smtp_host: String,
    smtp_port: Long,
    smtp_security: String,
  ) -> T): Query<T> = SelectImapConfigQuery(account_id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getLong(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4)!!,
      cursor.getLong(5)!!,
      cursor.getString(6)!!
    )
  }

  public fun selectImapConfig(account_id: String): Query<Imap_config> = selectImapConfig(account_id, ::Imap_config)

  /**
   * @return The number of rows updated.
   */
  public fun upsertImapConfig(
    account_id: String,
    imap_host: String,
    imap_port: Long,
    imap_security: String,
    smtp_host: String,
    smtp_port: Long,
    smtp_security: String,
  ): QueryResult<Long> {
    val result = driver.execute(-1_887_600_423, """INSERT OR REPLACE INTO imap_config VALUES (?, ?, ?, ?, ?, ?, ?)""", 7) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, imap_host)
          bindLong(parameterIndex++, imap_port)
          bindString(parameterIndex++, imap_security)
          bindString(parameterIndex++, smtp_host)
          bindLong(parameterIndex++, smtp_port)
          bindString(parameterIndex++, smtp_security)
        }
    notifyQueries(-1_887_600_423) { emit ->
      emit("imap_config")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteImapConfig(account_id: String): QueryResult<Long> {
    val result = driver.execute(-515_079_595, """DELETE FROM imap_config WHERE account_id = ?""", 1) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
        }
    notifyQueries(-515_079_595) { emit ->
      emit("imap_config")
    }
    return result
  }

  private inner class SelectImapConfigQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("imap_config", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("imap_config", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(1_332_936_806, """SELECT imap_config.account_id, imap_config.imap_host, imap_config.imap_port, imap_config.imap_security, imap_config.smtp_host, imap_config.smtp_port, imap_config.smtp_security FROM imap_config WHERE account_id = ?""", mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "ImapConfig.sq:selectImapConfig"
  }
}
