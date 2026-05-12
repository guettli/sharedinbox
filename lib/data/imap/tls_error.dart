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

/// If [error] is a TLS handshake failure caused by a wrong-version-number
/// (i.e. the server is not speaking TLS), throw a [TlsModeMismatchException]
/// with [host]/[port] context. Otherwise rethrow [error] unchanged.
Never rethrowAsTlsHint(Object error, StackTrace stack, String host, int port) {
  if (error.toString().contains('WRONG_VERSION_NUMBER')) {
    Error.throwWithStackTrace(
      TlsModeMismatchException(host, port, error),
      stack,
    );
  }
  Error.throwWithStackTrace(error, stack);
}
