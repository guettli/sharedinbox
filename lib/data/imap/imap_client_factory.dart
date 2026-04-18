import 'dart:io' show HandshakeException;

import 'package:enough_mail/enough_mail.dart';

import '../../core/models/account.dart';
import '../../core/utils/logger.dart';

/// Opens an authenticated IMAP client for [account] using [username].
Future<ImapClient> connectImap(
    Account account, String username, String password) async {
  final client = ImapClient();
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    isSecure: account.imapSsl,
  );
  await client.login(username, password);
  return client;
}

/// Opens an authenticated SMTP client for [account] using [username].
///
/// Caller is responsible for calling [SmtpClient.quit] when done.
Future<SmtpClient> connectSmtp(
    Account account, String username, String password) async {
  // clientDomain is the sending domain advertised in EHLO — use the host part
  // of the sender email, falling back to the SMTP host.
  final atIndex = account.email.lastIndexOf('@');
  final clientDomain =
      atIndex != -1 ? account.email.substring(atIndex + 1) : account.smtpHost;

  var client = SmtpClient(clientDomain);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: account.smtpSsl,
  );
  await client.ehlo();
  if (!account.smtpSsl) {
    // Opportunistic TLS on submission port (587).
    try {
      await client.startTls();
    } on HandshakeException catch (e) {
      // TLS handshake failure (e.g. self-signed cert) breaks the socket.
      // Reconnect plaintext so authenticate() can still proceed.
      log('STARTTLS handshake failed on ${account.smtpHost}: $e — reconnecting without TLS');
      client = SmtpClient(clientDomain);
      await client.connectToServer(
        account.smtpHost,
        account.smtpPort,
        isSecure: false,
      );
      await client.ehlo();
    } catch (e) {
      log('STARTTLS not available on ${account.smtpHost}: $e — continuing without TLS');
    }
  }
  await client.authenticate(username, password);
  return client;
}
