import 'package:enough_mail/enough_mail.dart';

import '../../core/models/account.dart';

/// Opens an authenticated IMAP client for the given account.
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

/// Opens an authenticated SMTP client for the given account.
Future<SmtpClient> connectSmtp(Account account, String password) async {
  final client = SmtpClient(account.displayName, isLogEnabled: false);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: account.smtpSsl,
  );
  await client.ehlo();
  if (!account.smtpSsl) {
    await client.startTls();
  }
  await client.authenticate(account.email, password, AuthMechanism.plain);
  return client;
}
