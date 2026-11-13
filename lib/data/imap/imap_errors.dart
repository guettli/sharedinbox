import 'dart:async' show TimeoutException;
import 'dart:io' show IOException;

import 'package:enough_mail/enough_mail.dart' show ImapException;

/// Returns true when [error] looks like an IMAP "this resource does not
/// exist" failure — typically the server rejecting `SELECT`, `STORE`, `MOVE`
/// or `COPY` with `NO [NONEXISTENT]` or `NO [TRYCREATE]` (RFC 3501 §7.1,
/// RFC 5530), or `enough_mail`'s loose "Mailbox does not exist" wording.
///
/// Used to recognise two distinct situations:
///   * A folder was deleted server-side between two sync cycles, so the
///     local cache row needs to be pruned.
///   * A single message is gone, so the pending change targeting it can be
///     dropped without retrying.
///
/// We string-match because `enough_mail` doesn't expose a typed error for
/// either case.
bool isImapMailboxNotFound(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('nonexistent') ||
      s.contains('does not exist') ||
      s.contains('trycreate') ||
      s.contains('not found');
}

/// Returns true when [error] means the IMAP connection itself is gone or no
/// longer trustworthy, so every further command on the same client is doomed:
///   * an [IOException] such as a `SocketException` ("Software caused
///     connection abort" when the phone switches networks) or a TLS error
///     mid-session,
///   * a command that got no answer in time — `enough_mail` reports its
///     `defaultResponseTimeout` as an [ImapException] whose message is exactly
///     `timeout`; a later response would be out of step with the next command,
///   * `enough_mail` writing to a socket it already closed, which surfaces as
///     `StateError('Cannot add event after closing')` or, from dart:io's
///     `IOSink`, `StateError('StreamSink is closed')`.
///
/// Callers that walk a batch of commands (e.g. the pending-change flush) stop
/// at the first such error instead of failing every remaining command one
/// timeout at a time.
bool isImapConnectionLost(Object error) {
  if (error is IOException || error is TimeoutException) return true;
  if (error is ImapException) return error.message == 'timeout';
  if (error is StateError) {
    return error.message.contains('Cannot add event after closing') ||
        error.message.contains('StreamSink is closed');
  }
  return false;
}
