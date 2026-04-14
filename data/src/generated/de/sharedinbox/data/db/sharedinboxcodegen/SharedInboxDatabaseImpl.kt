package de.sharedinbox.`data`.db.sharedinboxcodegen

import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.db.AfterVersion
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.db.SqlSchema
import de.sharedinbox.`data`.db.AccountQueries
import de.sharedinbox.`data`.db.EmailBodyQueries
import de.sharedinbox.`data`.db.EmailHeaderQueries
import de.sharedinbox.`data`.db.ImageTrustQueries
import de.sharedinbox.`data`.db.MailboxQueries
import de.sharedinbox.`data`.db.RecentAddressQueries
import de.sharedinbox.`data`.db.SettingsQueries
import de.sharedinbox.`data`.db.SharedInboxDatabase
import de.sharedinbox.`data`.db.StateTokenQueries
import de.sharedinbox.`data`.db.SyncLogQueries
import kotlin.Long
import kotlin.Unit
import kotlin.reflect.KClass

internal val KClass<SharedInboxDatabase>.schema: SqlSchema<QueryResult.Value<Unit>>
  get() = SharedInboxDatabaseImpl.Schema

internal fun KClass<SharedInboxDatabase>.newInstance(driver: SqlDriver): SharedInboxDatabase = SharedInboxDatabaseImpl(driver)

private class SharedInboxDatabaseImpl(
  driver: SqlDriver,
) : TransacterImpl(driver),
    SharedInboxDatabase {
  override val accountQueries: AccountQueries = AccountQueries(driver)

  override val emailBodyQueries: EmailBodyQueries = EmailBodyQueries(driver)

  override val emailHeaderQueries: EmailHeaderQueries = EmailHeaderQueries(driver)

  override val imageTrustQueries: ImageTrustQueries = ImageTrustQueries(driver)

  override val mailboxQueries: MailboxQueries = MailboxQueries(driver)

  override val recentAddressQueries: RecentAddressQueries = RecentAddressQueries(driver)

  override val settingsQueries: SettingsQueries = SettingsQueries(driver)

  override val stateTokenQueries: StateTokenQueries = StateTokenQueries(driver)

  override val syncLogQueries: SyncLogQueries = SyncLogQueries(driver)

  public object Schema : SqlSchema<QueryResult.Value<Unit>> {
    override val version: Long
      get() = 1

    override fun create(driver: SqlDriver): QueryResult.Value<Unit> {
      driver.execute(null, """
          |CREATE TABLE account (
          |    id               TEXT PRIMARY KEY,
          |    display_name     TEXT NOT NULL,
          |    base_url         TEXT NOT NULL,
          |    username         TEXT NOT NULL,
          |    jmap_account_id  TEXT NOT NULL,
          |    api_url          TEXT NOT NULL,
          |    upload_url       TEXT NOT NULL,
          |    download_url     TEXT NOT NULL,
          |    event_source_url TEXT NOT NULL,
          |    added_at         INTEGER NOT NULL
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE email_body (
          |    email_id   TEXT NOT NULL,
          |    account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    text_body  TEXT,
          |    html_body  TEXT,
          |    PRIMARY KEY (email_id, account_id)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE email_header (
          |    id             TEXT NOT NULL,
          |    account_id     TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    thread_id      TEXT NOT NULL,
          |    mailbox_id     TEXT NOT NULL,
          |    subject        TEXT,
          |    from_address   TEXT,
          |    received_at    INTEGER NOT NULL,
          |    keywords       TEXT NOT NULL DEFAULT '[]',
          |    has_attachment INTEGER NOT NULL DEFAULT 0,
          |    preview        TEXT,
          |    blob_id        TEXT NOT NULL DEFAULT '',
          |    PRIMARY KEY (id, account_id)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE image_trust (
          |    account_id TEXT NOT NULL,
          |    email_id   TEXT NOT NULL,
          |    PRIMARY KEY (account_id, email_id)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE mailbox (
          |    id            TEXT NOT NULL,
          |    account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    name          TEXT NOT NULL,
          |    role          TEXT,
          |    parent_id     TEXT,
          |    sort_order    INTEGER NOT NULL DEFAULT 0,
          |    unread_emails INTEGER NOT NULL DEFAULT 0,
          |    PRIMARY KEY (id, account_id)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE recent_address (
          |    email      TEXT    NOT NULL,
          |    name       TEXT,                          -- last known display name (may be null)
          |    account_id TEXT    NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    last_used  INTEGER NOT NULL,              -- epoch millis
          |    use_count  INTEGER NOT NULL DEFAULT 1,
          |    PRIMARY KEY (email, account_id)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE sync_settings (
          |    id               INTEGER PRIMARY KEY DEFAULT 1,
          |    mobile_days      INTEGER NOT NULL DEFAULT 60,
          |    mobile_mb_limit  INTEGER NOT NULL DEFAULT 1,
          |    wifi_days        INTEGER NOT NULL DEFAULT 400,
          |    wifi_mb_limit    INTEGER NOT NULL DEFAULT 10
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE state_token (
          |    account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    type_name  TEXT NOT NULL,
          |    state      TEXT NOT NULL,
          |    PRIMARY KEY (account_id, type_name)
          |)
          """.trimMargin(), 0)
      driver.execute(null, """
          |CREATE TABLE sync_log (
          |    id          INTEGER PRIMARY KEY AUTOINCREMENT,
          |    account_id  TEXT    NOT NULL REFERENCES account(id) ON DELETE CASCADE,
          |    occurred_at INTEGER NOT NULL,   -- epoch millis
          |    direction   TEXT    NOT NULL,   -- "server_to_db" | "db_to_server"
          |    operation   TEXT    NOT NULL,   -- e.g. "sync_mailboxes", "create_mailbox", "move_email"
          |    status      TEXT    NOT NULL,   -- "success" | "conflict" | "error"
          |    detail      TEXT                -- optional human-readable description or JSON
          |)
          """.trimMargin(), 0)
      return QueryResult.Unit
    }

    override fun migrate(
      driver: SqlDriver,
      oldVersion: Long,
      newVersion: Long,
      vararg callbacks: AfterVersion,
    ): QueryResult.Value<Unit> = QueryResult.Unit
  }
}
