package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class EmailBodyQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun <T : Any> selectEmailBody(
    account_id: String,
    email_id: String,
    mapper: (
      email_id: String,
      account_id: String,
      text_body: String?,
      html_body: String?,
    ) -> T,
  ): Query<T> = SelectEmailBodyQuery(account_id, email_id) { cursor ->
    mapper(
      cursor.getString(0)!!,
      cursor.getString(1)!!,
      cursor.getString(2),
      cursor.getString(3)
    )
  }

  public fun selectEmailBody(account_id: String, email_id: String): Query<Email_body> = selectEmailBody(account_id, email_id, ::Email_body)

  /**
   * @return The number of rows updated.
   */
  public fun upsertEmailBody(
    email_id: String,
    account_id: String,
    text_body: String?,
    html_body: String?,
  ): QueryResult<Long> {
    val result = driver.execute(1_900_249_109, """INSERT OR REPLACE INTO email_body VALUES (?, ?, ?, ?)""", 4) {
          var parameterIndex = 0
          bindString(parameterIndex++, email_id)
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, text_body)
          bindString(parameterIndex++, html_body)
        }
    notifyQueries(1_900_249_109) { emit ->
      emit("email_body")
    }
    return result
  }

  private inner class SelectEmailBodyQuery<out T : Any>(
    public val account_id: String,
    public val email_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("email_body", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("email_body", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-905_356_568, """SELECT email_body.email_id, email_body.account_id, email_body.text_body, email_body.html_body FROM email_body WHERE account_id = ? AND email_id = ?""", mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, email_id)
    }

    override fun toString(): String = "EmailBody.sq:selectEmailBody"
  }
}
