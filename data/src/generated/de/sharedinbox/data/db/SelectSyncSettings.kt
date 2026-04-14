package de.sharedinbox.`data`.db

import kotlin.Long

public data class SelectSyncSettings(
  public val mobile_days: Long,
  public val mobile_mb_limit: Long,
  public val wifi_days: Long,
  public val wifi_mb_limit: Long,
)
