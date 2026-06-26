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
