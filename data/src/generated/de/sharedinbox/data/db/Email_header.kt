package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Email_header(
  public val id: String,
  public val account_id: String,
  public val thread_id: String,
  public val mailbox_id: String,
  public val subject: String?,
  public val from_address: String?,
  public val received_at: Long,
  public val keywords: String,
  public val has_attachment: Long,
  public val preview: String?,
)
