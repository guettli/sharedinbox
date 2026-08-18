import 'dart:async';

import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

typedef ImapConnectFn = Future<ImapClient> Function(
  Account account,
  String username,
  String password,
);

/// Zone value key signalling that a [StringSink] for protocol logging is
/// active. When this key is non-null in the current zone, [connectImap]
/// enables IMAP trace logging so the output is captured by the zone's
/// print override.
const verboseLogKey = #verboseProtocolLog;

/// Opens an authenticated IMAP client for [account] using [username].
///
/// When the current [Zone] carries a capture sink under [verboseLogKey],
/// IMAP trace logging is enabled so each command/response is captured there.
Future<ImapClient> connectImap(
  Account account,
  String username,
  String password,
) async {
  final verboseSink = Zone.current[verboseLogKey];
  final client = ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
    isLogEnabled: verboseSink != null,
  );
  if (!account.imapSsl && !isLocalhost(account.imapHost)) {
    throw Exception(
      'Plain-text IMAP is only allowed for localhost connections',
    );
  }
  try {
    await client.connectToServer(
      account.imapHost,
      account.imapPort,
      isSecure: account.imapSsl,
    );
  } catch (e, st) {
    rethrowAsTlsHint(e, st, account.imapHost, account.imapPort);
  }
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

  if (!account.smtpSsl && !isLocalhost(account.smtpHost)) {
    throw Exception(
      'Plain-text SMTP is only allowed for localhost connections',
    );
  }
  final client = SmtpClient(clientDomain);
  try {
    await client.connectToServer(
      account.smtpHost,
      account.smtpPort,
      isSecure: account.smtpSsl,
    );
  } catch (e, st) {
    rethrowAsTlsHint(e, st, account.smtpHost, account.smtpPort);
  }
  await client.ehlo();
  if (!account.smtpSsl) {
    // STARTTLS required on submission port (587). No plaintext fallback.
    try {
      await client.startTls();
    } catch (e, st) {
      rethrowAsTlsHint(e, st, account.smtpHost, account.smtpPort);
    }
  }
  await client.authenticate(username, password);
  return client;
}
