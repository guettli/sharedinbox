package de.sharedinbox.data.imap

actual suspend fun checkImapSmtpConnection(
    username: String,
    password: String,
    imapHost: String,
    imapPort: Int,
    imapSecurity: String,
    smtpHost: String,
    smtpPort: Int,
    smtpSecurity: String,
): Result<Unit> = Result.failure(UnsupportedOperationException("IMAP/SMTP connection check is not supported on iOS"))
