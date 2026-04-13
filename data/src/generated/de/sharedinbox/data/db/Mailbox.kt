package de.sharedinbox.`data`.db

import kotlin.Long
import kotlin.String

public data class Mailbox(
  public val id: String,
  public val account_id: String,
  public val name: String,
  public val role: String?,
  public val parent_id: String?,
  public val sort_order: Long,
  public val unread_emails: Long,
)
