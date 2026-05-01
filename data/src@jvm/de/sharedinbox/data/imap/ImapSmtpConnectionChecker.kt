package de.sharedinbox.data.imap

import io.github.kmpmail.imap.ImapClient
import io.github.kmpmail.imap.ImapSecurity
import io.github.kmpmail.smtp.SmtpClient
import io.github.kmpmail.smtp.SmtpSecurity

actual suspend fun checkImapSmtpConnection(
    username: String,
    password: String,
    imapHost: String,
    imapPort: Int,
    imapSecurity: String,
    smtpHost: String,
    smtpPort: Int,
    smtpSecurity: String,
): Result<Unit> =
    runCatching {
        val imapClient =
            ImapClient {
                host = imapHost
                port = imapPort
                security = ImapSecurity.valueOf(imapSecurity)
                this.username = username
                this.password = password
            }
        imapClient.connect()
        imapClient.disconnect()

        val smtpClient =
            SmtpClient {
                host = smtpHost
                port = smtpPort
                security = SmtpSecurity.valueOf(smtpSecurity)
                credentials(username, password)
            }
        smtpClient.connect()
        smtpClient.disconnect()
    }
