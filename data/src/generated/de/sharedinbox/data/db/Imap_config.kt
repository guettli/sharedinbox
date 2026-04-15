package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Imap_config(
  public val account_id: String,
  public val imap_host: String,
  public val imap_port: Long,
  public val imap_security: String,
  public val smtp_host: String,
  public val smtp_port: Long,
  public val smtp_security: String,
)
