import 'package:enough_mail/enough_mail.dart';

import '../../core/models/account.dart';
import '../../core/utils/logger.dart';

/// Opens an authenticated IMAP client for [account].
Future<ImapClient> connectImap(Account account, String password) async {
  final client = ImapClient(isLogEnabled: false);
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    isSecure: account.imapSsl,
  );
  await client.login(account.email, password);
  return client;
}

/// Opens an authenticated SMTP client for [account].
///
/// Caller is responsible for calling [SmtpClient.quit] when done.
Future<SmtpClient> connectSmtp(Account account, String password) async {
  // clientDomain is the sending domain advertised in EHLO — use the host part
  // of the sender email, falling back to the SMTP host.
  final atIndex = account.email.lastIndexOf('@');
  final clientDomain =
      atIndex != -1 ? account.email.substring(atIndex + 1) : account.smtpHost;

  final client = SmtpClient(clientDomain, isLogEnabled: false);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: account.smtpSsl,
  );
  await client.ehlo();
  if (!account.smtpSsl) {
    // Opportunistic TLS on submission port (587)
    try {
      await client.startTls();
    } catch (e) {
      log('STARTTLS not available on ${account.smtpHost}: $e — continuing without TLS');
    }
  }
  await client.authenticate(account.email, password);
  return client;
}
