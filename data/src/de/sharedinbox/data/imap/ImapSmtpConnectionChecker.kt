package de.sharedinbox.data.imap

expect suspend fun checkImapSmtpConnection(
    username: String,
    password: String,
    imapHost: String,
    imapPort: Int,
    imapSecurity: String,
    smtpHost: String,
    smtpPort: Int,
    smtpSecurity: String,
): Result<Unit>
