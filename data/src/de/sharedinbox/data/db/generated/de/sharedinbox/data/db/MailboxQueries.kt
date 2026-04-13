package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class MailboxQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectMailboxesByAccount(account_id: String, mapper: (
    id: String,
    account_id: String,
    name: String,
    role: String?,
    parent_id: String?,
    sort_order: Long,
    unread_emails: Long,
  ) -> T): Query<T> = SelectMailboxesByAccountQuery(account_id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3),
      cursor.getString(4),
      cursor.getLong(5)!!,
      cursor.getLong(6)!!
    )
  }

  public fun selectMailboxesByAccount(account_id: String): Query<Mailbox> = selectMailboxesByAccount(account_id, ::Mailbox)

  public fun <T : Any> selectMailbox(
    account_id: String,
    id: String,
    mapper: (
      id: String,
      account_id: String,
      name: String,
      role: String?,
      parent_id: String?,
      sort_order: Long,
      unread_emails: Long,
    ) -> T,
  ): Query<T> = SelectMailboxQuery(account_id, id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3),
      cursor.getString(4),
      cursor.getLong(5)!!,
      cursor.getLong(6)!!
    )
  }

  public fun selectMailbox(account_id: String, id: String): Query<Mailbox> = selectMailbox(account_id, id, ::Mailbox)

  /**
   * @return The number of rows updated.
   */
  public fun upsertMailbox(
    id: String,
    account_id: String,
    name: String,
    role: String?,
    parent_id: String?,
    sort_order: Long,
    unread_emails: Long,
  ): QueryResult<Long> {
    val result = driver.execute(1_472_183_573, """INSERT OR REPLACE INTO mailbox VALUES (?, ?, ?, ?, ?, ?, ?)""", 7) {
          var parameterIndex = 0
          bindString(parameterIndex++, id)
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, name)
          bindString(parameterIndex++, role)
          bindString(parameterIndex++, parent_id)
          bindLong(parameterIndex++, sort_order)
          bindLong(parameterIndex++, unread_emails)
        }
    notifyQueries(1_472_183_573) { emit ->
      emit("mailbox")
    }
    return result
  }

  private inner class SelectMailboxesByAccountQuery<out T : Any>(
    public val account_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("mailbox", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("mailbox", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-157_703_392, """SELECT mailbox.id, mailbox.account_id, mailbox.name, mailbox.role, mailbox.parent_id, mailbox.sort_order, mailbox.unread_emails FROM mailbox WHERE account_id = ? ORDER BY sort_order""", mapper, 1) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
    }

    override fun toString(): String = "Mailbox.sq:selectMailboxesByAccount"
  }

  private inner class SelectMailboxQuery<out T : Any>(
    public val account_id: String,
    public val id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("mailbox", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("mailbox", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(1_674_850_472, """SELECT mailbox.id, mailbox.account_id, mailbox.name, mailbox.role, mailbox.parent_id, mailbox.sort_order, mailbox.unread_emails FROM mailbox WHERE account_id = ? AND id = ?""", mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, id)
    }

    override fun toString(): String = "Mailbox.sq:selectMailbox"
  }
}
