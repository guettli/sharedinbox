package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Account(
  public val id: String,
  public val display_name: String,
  public val base_url: String,
  public val username: String,
  public val jmap_account_id: String,
  public val api_url: String,
  public val upload_url: String,
  public val download_url: String,
  public val event_source_url: String,
  public val added_at: Long,
)
