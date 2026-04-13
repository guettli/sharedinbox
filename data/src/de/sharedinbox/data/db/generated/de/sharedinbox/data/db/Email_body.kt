package de.sharedinbox.`data`.db

import kotlin.String

public data class Email_body(
  public val email_id: String,
  public val account_id: String,
  public val text_body: String?,
  public val html_body: String?,
)
