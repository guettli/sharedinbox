import 'dart:async';
import 'dart:io' show SocketException;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

typedef ImapConnectFn = Future<ImapClient> Function(
  Account account,
  String username,
  String password,
);

/// Delays between connect attempts. A transient DNS hiccup right after a
/// network change on mobile (`SocketException: Failed host lookup`, #609)
/// usually clears within a second, so two quick retries avoid surfacing a
/// spurious sync failure while keeping the total added latency under 2s so a
/// genuinely offline device still fails fast into the loop-level backoff.
const _connectRetryDelays = [
  Duration(milliseconds: 500),
  Duration(milliseconds: 1500),
];

/// True when [e] is a transient socket/DNS failure worth retrying at the
/// connect layer. TLS and auth errors are permanent for the current config and
/// must not be retried — they flow on to [rethrowAsTlsHint] / login instead.
bool _isTransientConnectError(Object e) =>
    e is SocketException || e is TimeoutException;

/// Runs [connect] (a raw `connectToServer` call), retrying a bounded number of
/// times when the failure is a transient socket/DNS error. The last failure is
/// rethrown unchanged so callers still see the original exception.
@visibleForTesting
Future<void> connectWithRetry(Future<void> Function() connect) async {
  var attempt = 0;
  while (true) {
    try {
      await connect();
      return;
    } catch (e) {
      if (attempt >= _connectRetryDelays.length ||
          !_isTransientConnectError(e)) {
        rethrow;
      }
      await Future<void>.delayed(_connectRetryDelays[attempt]);
      attempt++;
    }
  }
}

/// Zone value key signalling that a [StringSink] for protocol logging is
/// active. When this key is non-null in the current zone, [connectImap]
/// enables IMAP trace logging so the output is captured by the zone's
/// print override.
const verboseLogKey = #verboseProtocolLog;

/// True when [connectImap] must upgrade a plaintext connection to [host] via
/// STARTTLS: `imapSsl: false` means "STARTTLS required" for every remote host,
/// while localhost keeps plaintext for the dev Stalwart (`stalwart-dev/`,
/// `test/backend/stalwart_harness.dart`), which has no certificate.
@visibleForTesting
bool imapNeedsStartTls({required bool imapSsl, required String host}) =>
    !imapSsl && !isLocalhost(host);

/// Issues `STARTTLS` on an already-connected plaintext [client] and requires
/// the upgrade to succeed. No plaintext fallback: a server that does not
/// advertise STARTTLS on this port is a misconfiguration, not something to
/// silently downgrade.
@visibleForTesting
Future<void> upgradeImapToStartTls(
  ImapClient client,
  String host,
  int port,
) async {
  final capabilities = client.serverInfo.capabilities;
  if (capabilities == null || capabilities.isEmpty) {
    // The greeting only carries capabilities when the server includes a
    // `[CAPABILITY …]` response code, so ask explicitly otherwise.
    await client.capability();
  }
  if (!client.serverInfo.supportsStartTls) {
    throw Exception(
      'Server at $host:$port does not advertise STARTTLS — turn SSL/TLS on '
      'and use the implicit-TLS port (usually 993), or point at a port that '
      'offers STARTTLS.',
    );
  }
  try {
    await client.startTls();
  } catch (e, st) {
    rethrowAsTlsHint(e, st, host, port, hint: 'IMAP STARTTLS upgrade');
  }
}

/// Opens an authenticated IMAP client for [account] using [username].
///
/// When [Account.imapSsl] is false, STARTTLS is required and the connection
/// fails if the server does not support it — except on localhost, where
/// plaintext stays legitimate for the dev Stalwart (see [imapNeedsStartTls]).
/// RFC 3501 requires discarding pre-TLS capabilities after STARTTLS; `login()`
/// repopulates them from the server's post-login CAPABILITY response.
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
  try {
    await connectWithRetry(
      () => client.connectToServer(
        account.imapHost,
        account.imapPort,
        isSecure: account.imapSsl,
      ),
    );
  } catch (e, st) {
    rethrowAsTlsHint(e, st, account.imapHost, account.imapPort);
  }
  if (imapNeedsStartTls(imapSsl: account.imapSsl, host: account.imapHost)) {
    await upgradeImapToStartTls(client, account.imapHost, account.imapPort);
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

  final client = SmtpClient(clientDomain);
  try {
    await connectWithRetry(
      () => client.connectToServer(
        account.smtpHost,
        account.smtpPort,
        isSecure: account.smtpSsl,
      ),
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
