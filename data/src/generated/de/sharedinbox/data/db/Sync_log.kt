package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Sync_log(
  public val id: Long,
  public val account_id: String,
  public val occurred_at: Long,
  public val direction: String,
  public val operation: String,
  public val status: String,
  public val detail: String?,
)
