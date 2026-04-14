package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Recent_address(
  public val email: String,
  public val name: String?,
  public val account_id: String,
  public val last_used: Long,
  public val use_count: Long,
)
