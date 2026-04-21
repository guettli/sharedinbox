import 'package:enough_mail/enough_mail.dart';

import '../../core/models/account.dart';

typedef ImapConnectFn = Future<ImapClient> Function(
  Account account,
  String username,
  String password,
);

/// Opens an authenticated IMAP client for [account] using [username].
///
/// Throws [Exception] if the account is not configured for SSL/TLS.
Future<ImapClient> connectImap(
  Account account,
  String username,
  String password,
) async {
  if (!account.imapSsl) {
    throw Exception(
      'Unencrypted IMAP connections are not allowed. Enable SSL/TLS.',
    );
  }
  final client =
      ImapClient(defaultResponseTimeout: const Duration(seconds: 20));
  await client.connectToServer(account.imapHost, account.imapPort);
  await client.login(username, password);
  return client;
}

/// Opens an authenticated SMTP client for [account] using [username].
///
/// When [account.smtpSsl] is false, STARTTLS is required and the connection
/// fails if the server does not support it. Plaintext fallback is not allowed.
///
/// Caller is responsible for calling [SmtpClient.quit] when done.
Future<SmtpClient> connectSmtp(
  Account account,
  String username,
  String password,
) async {
  // clientDomain is the sending domain advertised in EHLO — use the host part
  // of the sender email, falling back to the SMTP host.
  final atIndex = account.email.lastIndexOf('@');
  final clientDomain =
      atIndex != -1 ? account.email.substring(atIndex + 1) : account.smtpHost;

  final client = SmtpClient(clientDomain);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: account.smtpSsl,
  );
  await client.ehlo();
  if (!account.smtpSsl) {
    // STARTTLS required on submission port (587). No plaintext fallback.
    await client.startTls();
  }
  await client.authenticate(username, password);
  return client;
}
