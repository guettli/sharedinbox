import 'dart:async' show TimeoutException;
import 'dart:io' show IOException;

import 'package:enough_mail/enough_mail.dart' show ImapClient, ImapException;

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
/// either case. A match is only a hint: a text such as "not found" may name
/// something else than the folder, so before sync removes a folder (and its
/// cached mail) it asks [confirmImapMailboxGone]. The move/copy destination
/// check (`NO [TRYCREATE]`, which fails the change, listed) may use it as is.
bool isImapMailboxNotFound(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('nonexistent') ||
      s.contains('does not exist') ||
      s.contains('trycreate') ||
      s.contains('not found');
}

/// Returns true when [error] is a `NO` carrying the `[NONEXISTENT]` response
/// code (RFC 5530): the server says the folder does not exist, a definite
/// answer, unlike a text match ([isImapMailboxNotFound]).
bool isImapNonexistent(Object error) =>
    error is ImapException &&
    error.toString().toUpperCase().contains('[NONEXISTENT]');

/// After a command on the folder [path] failed with [error]: whether the
/// folder is gone on the server for sure, so sync may remove it with its
/// cached mail (#1312). Yes on a `NO [NONEXISTENT]` ([isImapNonexistent]).
/// An error that only reads like "no such folder" ([isImapMailboxNotFound],
/// e.g. a plain "not found") is checked with a LIST over [client]: gone
/// when a listing that has INBOX does not have [path]. An empty listing, one
/// without INBOX, a failed LIST, any other error or a lost connection say
/// nothing: false. INBOX itself is never gone (RFC 3501 §5.1: every account
/// has one), whatever the server answers.
///
/// The LIST is the account's full `LIST "" *`, not one of [path] alone:
/// enough_mail 2.1.7 encodes a LIST pattern's last segment only, so a path
/// with a non-ASCII parent would list nothing and look gone; the full
/// listing also shows whether the answer is complete (INBOX). Its verdict
/// is kept per connection and path, so a pass that hits the same folder
/// again (a flush of several changes) lists once.
Future<bool> confirmImapMailboxGone(
  ImapClient client,
  String path,
  Object error,
) async {
  if (path.toUpperCase() == 'INBOX') return false;
  if (isImapNonexistent(error)) return true;
  if (!isImapMailboxNotFound(error) || isImapConnectionLost(error)) {
    return false;
  }
  if (!client.isConnected) return false;
  final verdicts = _listVerdicts[client] ??= {};
  if (verdicts[path] case final known?) return known;
  final bool gone;
  try {
    final listed = await client.listMailboxes(recursive: true);
    gone = listed.any((m) => m.path.toUpperCase() == 'INBOX') &&
        !listed.any((m) => m.path == path || m.encodedPath == path);
  } catch (_) {
    // Not kept: the next try may get an answer.
    return false;
  }
  return verdicts[path] = gone;
}

/// [confirmImapMailboxGone]'s LIST verdicts, per connection and path.
final _listVerdicts = Expando<Map<String, bool>>('imapListVerdicts');

/// Returns true when [error] is a `NO` with a response code saying the
/// command can never succeed as sent (RFC 5530): `[CANNOT]`, `[NOPERM]`,
/// `[CONTACTADMIN]`, `[PRIVACYREQUIRED]`, or `[READ-ONLY]` for a write to a
/// mailbox opened read-only. Retrying cannot help, so a queued change that
/// gets one is refused at once (SYNC.md §6). Other `NO`s may pass later.
bool isImapPermanentRefusal(Object error) {
  if (error is! ImapException) return false;
  final s = error.toString().toUpperCase();
  return s.contains('[CANNOT]') ||
      s.contains('[NOPERM]') ||
      s.contains('[CONTACTADMIN]') ||
      s.contains('[PRIVACYREQUIRED]') ||
      s.contains('[READ-ONLY]');
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
