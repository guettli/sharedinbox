package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class EmailHeaderQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectEmailsByMailbox(
    account_id: String,
    mailbox_id: String,
    mapper: (
      id: String,
      account_id: String,
      thread_id: String,
      mailbox_id: String,
      subject: String?,
      from_address: String?,
      received_at: Long,
      keywords: String,
      has_attachment: Long,
      preview: String?,
      blob_id: String,
    ) -> T,
  ): Query<T> = SelectEmailsByMailboxQuery(account_id, mailbox_id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4),
      cursor.getString(5),
      cursor.getLong(6)!!,
      cursor.getString(7)!!,
      cursor.getLong(8)!!,
      cursor.getString(9),
      cursor.getString(10)!!
    )
  }

  public fun selectEmailsByMailbox(account_id: String, mailbox_id: String): Query<Email_header> = selectEmailsByMailbox(account_id, mailbox_id, ::Email_header)

  public fun <T : Any> selectEmailById(
    account_id: String,
    id: String,
    mapper: (
      id: String,
      account_id: String,
      thread_id: String,
      mailbox_id: String,
      subject: String?,
      from_address: String?,
      received_at: Long,
      keywords: String,
      has_attachment: Long,
      preview: String?,
      blob_id: String,
    ) -> T,
  ): Query<T> = SelectEmailByIdQuery(account_id, id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2)!!,
      cursor.getString(3)!!,
      cursor.getString(4),
      cursor.getString(5),
      cursor.getLong(6)!!,
      cursor.getString(7)!!,
      cursor.getLong(8)!!,
      cursor.getString(9),
      cursor.getString(10)!!
    )
  }

  public fun selectEmailById(account_id: String, id: String): Query<Email_header> = selectEmailById(account_id, id, ::Email_header)

  /**
   * @return The number of rows updated.
   */
  public fun upsertEmailHeader(
    id: String,
    account_id: String,
    thread_id: String,
    mailbox_id: String,
    subject: String?,
    from_address: String?,
    received_at: Long,
    keywords: String,
    has_attachment: Long,
    preview: String?,
    blob_id: String,
  ): QueryResult<Long> {
    val result = driver.execute(-175_662_411, """INSERT OR REPLACE INTO email_header VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", 11) {
          var parameterIndex = 0
          bindString(parameterIndex++, id)
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, thread_id)
          bindString(parameterIndex++, mailbox_id)
          bindString(parameterIndex++, subject)
          bindString(parameterIndex++, from_address)
          bindLong(parameterIndex++, received_at)
          bindString(parameterIndex++, keywords)
          bindLong(parameterIndex++, has_attachment)
          bindString(parameterIndex++, preview)
          bindString(parameterIndex++, blob_id)
        }
    notifyQueries(-175_662_411) { emit ->
      emit("email_header")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteEmailHeader(account_id: String, id: String): QueryResult<Long> {
    val result = driver.execute(-577_189_703, """DELETE FROM email_header WHERE account_id = ? AND id = ?""", 2) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, id)
        }
    notifyQueries(-577_189_703) { emit ->
      emit("email_header")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun deleteEmailHeadersByAccount(account_id: String): QueryResult<Long> {
    val result = driver.execute(832_617_500, """DELETE FROM email_header WHERE account_id = ?""", 1) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
        }
    notifyQueries(832_617_500) { emit ->
      emit("email_header")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun updateEmailKeywords(
    keywords: String,
    account_id: String,
    id: String,
  ): QueryResult<Long> {
    val result = driver.execute(1_261_467_768, """UPDATE email_header SET keywords = ? WHERE account_id = ? AND id = ?""", 3) {
          var parameterIndex = 0
          bindString(parameterIndex++, keywords)
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, id)
        }
    notifyQueries(1_261_467_768) { emit ->
      emit("email_header")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun updateEmailMailboxId(
    mailbox_id: String,
    account_id: String,
    id: String,
  ): QueryResult<Long> {
    val result = driver.execute(1_107_391_969, """UPDATE email_header SET mailbox_id = ? WHERE account_id = ? AND id = ?""", 3) {
          var parameterIndex = 0
          bindString(parameterIndex++, mailbox_id)
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, id)
        }
    notifyQueries(1_107_391_969) { emit ->
      emit("email_header")
    }
    return result
  }

  private inner class SelectEmailsByMailboxQuery<out T : Any>(
    public val account_id: String,
    public val mailbox_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("email_header", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("email_header", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-1_348_043_323, """
    |SELECT email_header.id, email_header.account_id, email_header.thread_id, email_header.mailbox_id, email_header.subject, email_header.from_address, email_header.received_at, email_header.keywords, email_header.has_attachment, email_header.preview, email_header.blob_id FROM email_header
    |WHERE account_id = ? AND mailbox_id = ?
    |ORDER BY received_at DESC
    """.trimMargin(), mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, mailbox_id)
    }

    override fun toString(): String = "EmailHeader.sq:selectEmailsByMailbox"
  }

  private inner class SelectEmailByIdQuery<out T : Any>(
    public val account_id: String,
    public val id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("email_header", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("email_header", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-379_135_795, """SELECT email_header.id, email_header.account_id, email_header.thread_id, email_header.mailbox_id, email_header.subject, email_header.from_address, email_header.received_at, email_header.keywords, email_header.has_attachment, email_header.preview, email_header.blob_id FROM email_header WHERE account_id = ? AND id = ?""", mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, id)
    }

    override fun toString(): String = "EmailHeader.sq:selectEmailById"
  }
}
