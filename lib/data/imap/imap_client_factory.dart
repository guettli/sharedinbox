import 'dart:async';
import 'dart:io' show SocketException;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/data/imap/rcpt_checking_smtp_client.dart';
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
/// Neither is a missing greeting ([_GreetingTimeoutException]): the server
/// accepted the connection and then stayed silent for the whole bound, which
/// a retry a second later will not change — it only multiplies the wait.
bool _isTransientConnectError(Object e) =>
    e is SocketException ||
    (e is TimeoutException && e is! _GreetingTimeoutException);

/// No server greeting within [_imapGreetingTimeout].
class _GreetingTimeoutException extends TimeoutException {
  _GreetingTimeoutException(String host)
      : super('No IMAP greeting from $host', _imapGreetingTimeout);
}

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

/// True when connecting [account] over IMAP must upgrade the plaintext
/// connection with STARTTLS before logging in.
///
/// `imapSsl: false` means "STARTTLS required" — except on localhost, where
/// plaintext stays legitimate for the dev Stalwart (`stalwart-dev/`,
/// `test/backend/stalwart_harness.dart`), which has no certificate configured.
@visibleForTesting
bool imapNeedsStartTls(Account account) =>
    !account.imapSsl && !isLocalhost(account.imapHost);

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
  // The greeting only populates capabilities when it carries a
  // `[CAPABILITY …]` response code; ask explicitly otherwise.
  final caps = client.serverInfo.capabilities;
  if (caps == null || caps.isEmpty) {
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
  // RFC 3501 §6.2.1 / RFC 2595 §3.1: capabilities announced before STARTTLS
  // are MUST-discard, because they were sent over cleartext and an active MITM
  // can author them. enough_mail does not re-fetch on upgrade (the secured
  // socket reuses the connection without re-running the greeting handler) and
  // login() overwrites them only when the server volunteers an `OK
  // [CAPABILITY …]` code, so issue CAPABILITY explicitly on the secure channel.
  await client.capability();
}

/// Bound on the server greeting. enough_mail's own connect timeout covers
/// only the TCP/TLS connect, and its `defaultResponseTimeout` (set below)
/// only tagged command responses, so a connection that is accepted but then
/// blackholed (no bytes flow — e.g. a captive portal or a stale NAT path)
/// used to hang the sync loop waiting for the greeting forever.
const _imapGreetingTimeout = Duration(seconds: 45);

/// [ImapClient] that fails a pending [connectToServer] as soon as the socket
/// dies before the server greeting.
///
/// enough_mail completes its greeting future only from the first received
/// bytes: a socket error or close in between (Android's `Software caused
/// connection abort`, errno 103, when the network drops mid-handshake) only
/// reaches [onConnectionError], so the connect sat out the whole
/// [_imapGreetingTimeout] and was then reported as "the server did not answer
/// in time" — and, being a greeting timeout, was not retried either.
class _GreetingAwareImapClient extends ImapClient {
  _GreetingAwareImapClient({
    super.defaultWriteTimeout,
    super.defaultResponseTimeout,
    super.isLogEnabled,
  });

  Completer<void>? _lostBeforeGreeting;

  @override
  void onConnectionError(dynamic error) {
    super.onConnectionError(error);
    final lost = _lostBeforeGreeting;
    if (lost == null || lost.isCompleted) return;
    lost.completeError(
      error is SocketException
          ? error
          : SocketException('Connection closed before the IMAP greeting '
              '($error)'),
    );
  }
}

/// One connect attempt of [connectImap], bounded by [_imapGreetingTimeout]
/// and failing fast when the connection is lost before the greeting.
Future<void> _connectBounded(
  _GreetingAwareImapClient client,
  Account account,
) async {
  final lost = Completer<void>();
  client._lostBeforeGreeting = lost;
  try {
    await Future.any([
      client.connectToServer(
        account.imapHost,
        account.imapPort,
        isSecure: account.imapSsl,
      ),
      lost.future,
    ]).timeout(
      _imapGreetingTimeout,
      onTimeout: () {
        // Not retried (see [_isTransientConnectError]), so this cannot
        // close a later attempt's socket.
        unawaited(client.disconnect());
        throw _GreetingTimeoutException(account.imapHost);
      },
    );
  } finally {
    client._lostBeforeGreeting = null;
  }
}

/// Bound on writing one IMAP command and on waiting for its tagged response.
const _imapCommandTimeout = Duration(seconds: 20);

/// Ends an IMAP session opened by [connectImap]; never throws.
///
/// Use this in `finally` blocks instead of a bare `logout()`: when the
/// connection was lost mid-command, LOGOUT fails with enough_mail's
/// "Bad state: Cannot add event after closing", and an exception thrown from
/// `finally` replaces the real error (the `SocketException`) that ended the
/// session, so the sync log reported the LOGOUT failure instead.
///
/// LOGOUT is only sent when [logout] is true and the connection is still up;
/// otherwise, or when LOGOUT fails, the socket is just dropped. Each step is
/// bounded by [timeout], kept short so closing a half-open connection (still
/// "connected", but no bytes flow) does not hold back the error that ended
/// the session for long.
///
/// After a write timeout enough_mail fails every later write on [client], and
/// once the server has closed the connection `disconnect()` does nothing;
/// in both cases the OS reclaims the socket.
Future<void> closeImapClient(
  ImapClient client, {
  bool logout = true,
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    if (logout && client.isConnected) {
      await client.logout().timeout(timeout);
      return;
    }
  } catch (_) {
    // Fall through and drop the connection.
  }
  try {
    await client.disconnect().timeout(timeout);
  } catch (_) {
    // Nothing left to clean up.
  }
}

/// Opens an authenticated IMAP client for [account] using [username].
///
/// When [account.imapSsl] is false, STARTTLS is required and the connection
/// fails if the server does not support it — except on localhost, where
/// plaintext is allowed for the dev server (see [imapNeedsStartTls]).
/// [upgradeImapToStartTls] re-issues CAPABILITY on the secure channel so the
/// pre-STARTTLS capability list is discarded per RFC 3501 §6.2.1.
///
/// When the current [Zone] carries a capture sink under [verboseLogKey],
/// IMAP trace logging is enabled so each command/response is captured there.
Future<ImapClient> connectImap(
  Account account,
  String username,
  String password,
) async {
  final verboseSink = Zone.current[verboseLogKey];
  final client = _GreetingAwareImapClient(
    // Without a write timeout a command written to a dead connection (Android
    // after a network switch) waits for the kernel to give up on the socket,
    // about five minutes, before the sync can fail and retry.
    defaultWriteTimeout: _imapCommandTimeout,
    defaultResponseTimeout: _imapCommandTimeout,
    isLogEnabled: verboseSink != null,
  );
  try {
    await connectWithRetry(() => _connectBounded(client, account));
  } catch (e, st) {
    rethrowConnectError(e, st, account.imapHost, account.imapPort);
  }
  if (imapNeedsStartTls(account)) {
    await upgradeImapToStartTls(client, account.imapHost, account.imapPort);
  }
  await client.login(username, password);
  return client;
}

/// True when connecting [account] over SMTP must upgrade the plaintext
/// connection with STARTTLS before authenticating.
///
/// Mirrors [imapNeedsStartTls]: `smtpSsl: false` means "STARTTLS required" —
/// except on localhost, where plaintext stays legitimate for the dev server
/// (`test/backend`, port 25, which has no certificate configured).
@visibleForTesting
bool smtpNeedsStartTls(Account account) =>
    !account.smtpSsl && !isLocalhost(account.smtpHost);

/// Issues `STARTTLS` on an already-EHLO'd plaintext [client] and requires the
/// upgrade to succeed before any credential is sent. Two independent checks,
/// because either gap leaks the password over cleartext:
///
///  1. the server must advertise `STARTTLS` — an active MITM strips it from the
///     EHLO response to force a downgrade, so a missing capability is a refusal,
///     not a reason to continue; and
///  2. the command must answer with a success (2xx) status. `SmtpClient.
///     startTls()` upgrades the socket only on `isOkStatus` and otherwise
///     RETURNS the response rather than throwing — and a 1xx "accepted" status
///     is neither OK nor a failure, so without this check a stripped-STARTTLS
///     MITM that replies `150` leaves the socket in cleartext and the `AUTH`
///     that follows sends the password in the clear.
///
/// No plaintext fallback: a server that cannot complete STARTTLS on this port
/// is a misconfiguration, surfaced as an error, never a silent downgrade.
@visibleForTesting
Future<void> upgradeSmtpToStartTls(
  SmtpClient client,
  String host,
  int port,
) async {
  if (!client.serverInfo.supportsStartTls) {
    throw Exception(
      'Server at $host:$port does not advertise STARTTLS — turn SSL/TLS on '
      'and use the implicit-TLS port (usually 465), or point at a port that '
      'offers STARTTLS.',
    );
  }
  late final SmtpResponse response;
  try {
    response = await client.startTls();
  } catch (e, st) {
    rethrowAsTlsHint(e, st, host, port, hint: 'SMTP STARTTLS upgrade');
  }
  if (!response.isOkStatus) {
    throw Exception(
      'SMTP STARTTLS upgrade refused by $host:$port (${response.message}) — '
      'refusing to send credentials over an un-upgraded connection.',
    );
  }
}

/// Opens an authenticated SMTP client for [account] using [username].
///
/// When [account.smtpSsl] is false, STARTTLS is required and the connection
/// fails if the server does not support or complete it — except on localhost,
/// where plaintext is allowed for the dev server (see [smtpNeedsStartTls]).
/// Plaintext fallback to a remote host is never allowed.
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

  final client = RcptCheckingSmtpClient(clientDomain);
  try {
    await connectWithRetry(
      () => client.connectToServer(
        account.smtpHost,
        account.smtpPort,
        isSecure: account.smtpSsl,
      ),
    );
  } catch (e, st) {
    rethrowConnectError(e, st, account.smtpHost, account.smtpPort);
  }
  await client.ehlo();
  if (smtpNeedsStartTls(account)) {
    await upgradeSmtpToStartTls(client, account.smtpHost, account.smtpPort);
  }
  await client.authenticate(username, password);
  return client;
}
