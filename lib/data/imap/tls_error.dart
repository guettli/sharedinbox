import 'dart:io' show SocketException;

/// Wraps a low-level TLS handshake failure (typically from `dart:io`) into a
/// message that points the user at the most likely fix: a TLS-mode mismatch
/// between the client (implicit TLS or plaintext) and the server's listener
/// on that port.
///
/// `WRONG_VERSION_NUMBER` is BoringSSL's way of saying "I tried to read a TLS
/// record but the bytes don't look like TLS at all" — almost always because
/// the server on that port is plaintext or expects STARTTLS first.
class TlsModeMismatchException implements Exception {
  TlsModeMismatchException(this.host, this.port, this.original);
  final String host;
  final int port;
  final Object original;

  @override
  String toString() =>
      "TLS mode mismatch on $host:$port — the server isn't speaking implicit "
      "TLS on this port. Try toggling 'SSL/TLS' off (server uses STARTTLS), "
      'or change the port (e.g. 465 for implicit-TLS SMTP, 587 for SMTP+'
      'STARTTLS, 993 for IMAPS, 143 for IMAP+STARTTLS, 4190 for ManageSieve+'
      'STARTTLS). Original error: $original';
}

/// Wraps a TLS certificate verification failure into a user-actionable message.
///
/// Thrown when the server's certificate cannot be verified — either because it
/// is self-signed, expired, or the CA chain has changed since the account was
/// set up.
class TlsCertificateException implements Exception {
  TlsCertificateException(this.host, this.port, this.original);
  final String host;
  final int port;
  final Object original;

  @override
  String toString() =>
      'TLS certificate error on $host:$port — the server certificate could '
      'not be verified. The certificate may have changed or expired. '
      'Please re-check your account settings or contact your mail provider. '
      'Original error: $original';
}

/// Wraps a TLS handshake that was aborted by the peer without a cert-specific
/// alert — typically the server closed the TCP connection partway through the
/// negotiation, leaving us with `HandshakeException: Connection terminated
/// during handshake`, `Connection reset by peer`, or a generic TLS alert.
///
/// This is **not** the same as a certificate verification failure: blaming
/// the certificate (as we used to) is misleading because the most common
/// causes are server-side TLS misconfiguration (no cert bound to the port,
/// STARTTLS advertised but the upgrade fails), a middlebox/firewall closing
/// the connection, or an implicit-TLS vs STARTTLS mode mismatch that the
/// `WRONG_VERSION_NUMBER` heuristic did not catch.
class TlsHandshakeAbortedException implements Exception {
  TlsHandshakeAbortedException(
    this.host,
    this.port,
    this.original, {
    this.hint,
  });
  final String host;
  final int port;
  final Object original;

  /// Optional protocol-specific context, e.g. the server's STARTTLS reply
  /// captured just before the handshake was attempted. Surfacing it makes
  /// the eventual bug report much easier to triage.
  final String? hint;

  @override
  String toString() {
    final h = hint == null || hint!.isEmpty ? '' : ' [$hint]';
    return 'TLS handshake aborted on $host:$port$h — the connection was '
        'closed during TLS negotiation. Likely causes: the server has no '
        'valid certificate on this port, a firewall or proxy is dropping '
        'TLS connections, or the SSL/STARTTLS mode does not match what the '
        'server expects. Check the server logs, or run '
        '`openssl s_client -connect $host:$port -servername $host` (add '
        '`-starttls imap`, `-starttls smtp`, or `-starttls sieve` for the '
        'matching protocol) to see whether the server completes the '
        'handshake. Original error: $original';
  }
}

/// Returns true if [error] is a permanent TLS configuration error that will
/// not resolve on its own and requires user action.
///
/// [TlsHandshakeAbortedException] is intentionally excluded: a handshake
/// abort can be transient (server restart, momentary network glitch), so the
/// sync loop is allowed to keep retrying instead of giving up.
bool isTlsConfigError(Object error) =>
    error is TlsModeMismatchException || error is TlsCertificateException;

/// Rethrows a failed connect so the message names the server.
///
/// A refused connection surfaces from dart:io as `SocketException: Connection
/// refused …, address = localhost, port = 38920`, where the port is this
/// device's own source port, not the server's. Shown as is in the Outbox, it
/// pointed the user at a port they never configured. A [SocketException] is
/// rethrown as one again, so retry and offline handling still recognise it,
/// but as "Could not connect to host:port" plus the OS error. Anything else
/// goes on to [rethrowAsTlsHint].
///
/// Call it after any connect retries: the retry decision looks at the
/// original exception.
Never rethrowConnectError(
  Object error,
  StackTrace stack,
  String host,
  int port,
) {
  if (error is SocketException) {
    final os = error.osError;
    // "Connection refused" is both the message and the OS error's message;
    // say it once. A DNS failure ("Failed host lookup: 'x'") keeps its own.
    final detail =
        os != null && os.message == error.message ? '' : ': ${error.message}';
    Error.throwWithStackTrace(
      SocketException('Could not connect to $host:$port$detail', osError: os),
      stack,
    );
  }
  rethrowAsTlsHint(error, stack, host, port);
}

/// If [error] is a recognisable TLS handshake failure, wraps it in a typed
/// exception and throws it.  Otherwise rethrows [error] unchanged.
///
/// Recognised patterns:
/// - `WRONG_VERSION_NUMBER` → [TlsModeMismatchException] (port/mode mismatch)
/// - `CERTIFICATE_*` / `CertificateException` → [TlsCertificateException]
/// - Any other `HandshakeException` (e.g. "Connection terminated during
///   handshake", "Connection reset by peer", `TLSV1_ALERT_*`) →
///   [TlsHandshakeAbortedException]
///
/// [hint] is forwarded into [TlsHandshakeAbortedException] when set, so
/// callers that know something useful about the protocol state (e.g. the
/// server's STARTTLS reply just before the upgrade) can surface it in the
/// final message.
Never rethrowAsTlsHint(
  Object error,
  StackTrace stack,
  String host,
  int port, {
  String? hint,
}) {
  final s = error.toString();
  if (s.contains('WRONG_VERSION_NUMBER')) {
    Error.throwWithStackTrace(
      TlsModeMismatchException(host, port, error),
      stack,
    );
  }
  if (s.contains('CERTIFICATE_VERIFY_FAILED') ||
      s.contains('CERTIFICATE_EXPIRED') ||
      s.contains('CERTIFICATE_UNKNOWN') ||
      s.contains('CERTIFICATE_REQUIRED') ||
      s.contains('SELF_SIGNED') ||
      s.contains('CertificateException')) {
    Error.throwWithStackTrace(
      TlsCertificateException(host, port, error),
      stack,
    );
  }
  if (s.contains('HandshakeException') ||
      s.contains('TLSV1_ALERT') ||
      s.contains('BAD_RECORD_MAC')) {
    Error.throwWithStackTrace(
      TlsHandshakeAbortedException(host, port, error, hint: hint),
      stack,
    );
  }
  Error.throwWithStackTrace(error, stack);
}
