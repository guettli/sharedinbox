package de.sharedinbox.`data`.db

import app.cash.sqldelight.Transacter
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.db.SqlSchema
import de.sharedinbox.`data`.db.sharedinboxcodegen.newInstance
import de.sharedinbox.`data`.db.sharedinboxcodegen.schema
import kotlin.Unit

public interface SharedInboxDatabase : Transacter {
  public val accountQueries: AccountQueries

  public val emailBodyQueries: EmailBodyQueries

  public val emailHeaderQueries: EmailHeaderQueries

  public val imageTrustQueries: ImageTrustQueries

  public val mailboxQueries: MailboxQueries

  public val recentAddressQueries: RecentAddressQueries

  public val settingsQueries: SettingsQueries

  public val stateTokenQueries: StateTokenQueries

  public val syncLogQueries: SyncLogQueries

  public companion object {
    public val Schema: SqlSchema<QueryResult.Value<Unit>>
      get() = SharedInboxDatabase::class.schema

    public operator fun invoke(driver: SqlDriver): SharedInboxDatabase = SharedInboxDatabase::class.newInstance(driver)
  }
}
