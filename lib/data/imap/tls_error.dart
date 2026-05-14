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

/// Returns true if [error] is a permanent TLS configuration error that will
/// not resolve on its own and requires user action.
bool isTlsConfigError(Object error) =>
    error is TlsModeMismatchException || error is TlsCertificateException;

/// If [error] is a recognisable TLS handshake failure, wraps it in a typed
/// exception and throws it.  Otherwise rethrows [error] unchanged.
///
/// Recognised patterns:
/// - `WRONG_VERSION_NUMBER` → [TlsModeMismatchException] (port/mode mismatch)
/// - `CERTIFICATE_VERIFY_FAILED` / `HandshakeException` → [TlsCertificateException]
Never rethrowAsTlsHint(Object error, StackTrace stack, String host, int port) {
  final s = error.toString();
  if (s.contains('WRONG_VERSION_NUMBER')) {
    Error.throwWithStackTrace(
      TlsModeMismatchException(host, port, error),
      stack,
    );
  }
  if (s.contains('CERTIFICATE_VERIFY_FAILED') ||
      s.contains('HandshakeException') ||
      s.contains('CERTIFICATE_EXPIRED') ||
      s.contains('CERTIFICATE_UNKNOWN')) {
    Error.throwWithStackTrace(
      TlsCertificateException(host, port, error),
      stack,
    );
  }
  Error.throwWithStackTrace(error, stack);
}
