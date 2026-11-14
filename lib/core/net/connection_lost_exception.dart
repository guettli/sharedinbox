import 'dart:io' show SocketException;

/// The connection to the mail server died while a command was pending or
/// being sent (e.g. Android's `Software caused connection abort`, errno 103,
/// when the phone switches networks).
///
/// A [SocketException] so existing "transient network error" handling applies
/// unchanged; its own type lets the Sync Entry say what happened instead of
/// reporting the command's response timeout or enough_mail's
/// `Bad state: Cannot add event after closing` that follow it.
class ConnectionLostException extends SocketException {
  const ConnectionLostException(super.message, {super.osError});

  /// Wraps [cause], the socket error (or close) that ended the connection.
  factory ConnectionLostException.from(Object? cause) =>
      ConnectionLostException(
        'Connection to the mail server lost'
        '${cause == null ? '' : ' ($cause)'}',
        osError: cause is SocketException ? cause.osError : null,
      );

  @override
  String toString() => message;
}
