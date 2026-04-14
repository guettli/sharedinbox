package de.sharedinbox.`data`.db

import app.cash.sqldelight.Query
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlCursor
import app.cash.sqldelight.db.SqlDriver
import kotlin.Any
import kotlin.Long
import kotlin.String

public class ImageTrustQueries(
  driver: SqlDriver,
) : TransacterImpl(driver) {
  public fun isImageTrusted(account_id: String, email_id: String): Query<Long> = IsImageTrustedQuery(account_id, email_id) { cursor ->
    cursor.getLong(0)!!
  }

  /**
   * @return The number of rows updated.
   */
  public fun grantImageTrust(account_id: String, email_id: String): QueryResult<Long> {
    val result = driver.execute(918_279_996, """INSERT OR IGNORE INTO image_trust VALUES (?, ?)""", 2) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, email_id)
        }
    notifyQueries(918_279_996) { emit ->
      emit("image_trust")
    }
    return result
  }

  /**
   * @return The number of rows updated.
   */
  public fun revokeImageTrust(account_id: String, email_id: String): QueryResult<Long> {
    val result = driver.execute(-367_427_072, """DELETE FROM image_trust WHERE account_id = ? AND email_id = ?""", 2) {
          var parameterIndex = 0
          bindString(parameterIndex++, account_id)
          bindString(parameterIndex++, email_id)
        }
    notifyQueries(-367_427_072) { emit ->
      emit("image_trust")
    }
    return result
  }

  private inner class IsImageTrustedQuery<out T : Any>(
    public val account_id: String,
    public val email_id: String,
    mapper: (SqlCursor) -> T,
  ) : Query<T>(mapper) {
    override fun addListener(listener: Query.Listener) {
      driver.addListener("image_trust", listener = listener)
    }

    override fun removeListener(listener: Query.Listener) {
      driver.removeListener("image_trust", listener = listener)
    }

    override fun <R> execute(mapper: (SqlCursor) -> QueryResult<R>): QueryResult<R> = driver.executeQuery(-490_164_797, """SELECT COUNT(*) FROM image_trust WHERE account_id = ? AND email_id = ?""", mapper, 2) {
      var parameterIndex = 0
      bindString(parameterIndex++, account_id)
      bindString(parameterIndex++, email_id)
    }

    override fun toString(): String = "ImageTrust.sq:isImageTrusted"
  }
}
