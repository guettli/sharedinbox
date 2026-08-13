/// Why the local mail-cache database could not be opened at startup.
///
/// The distinction matters because the right message — and whether it is even
/// safe to offer a destructive "delete the cache" action — differs per cause.
enum DbUnreadableReason {
  /// The DB is marked encrypted but this build has no SQLCipher (e.g. the
  /// `source: sqlcipher` hook regressed). The data is intact; deleting it
  /// would be the wrong move, so no destructive action is offered.
  buildMissingCipher,

  /// The DB is marked encrypted but the secure-storage key is gone (device
  /// restore, keystore reset). The cache is unrecoverable by anyone.
  keyMissing,

  /// The key is present but the file cannot be opened (wrong key, or a cipher
  /// format this build cannot read — the "old DB written by another version"
  /// case).
  wrongKeyOrFormat,

  /// Any other open failure — genuine corruption.
  corrupt,
}

/// SQLite primary result code for "file is not a database" (SQLITE_NOTADB).
const int sqliteNotADb = 26;

/// Classifies why opening the DB failed, from cheaply-observable facts.
///
/// Pure so it can be unit-tested exhaustively without a native SQLite build.
/// [sqliteResultCode] is the *primary* result code (extended bits stripped),
/// as exposed by `SqliteException.resultCode`.
DbUnreadableReason classifyDbOpenFailure({
  required bool markerPresent,
  required bool hasKey,
  required bool cipherAvailable,
  required int? sqliteResultCode,
}) {
  if (markerPresent && !cipherAvailable) {
    return DbUnreadableReason.buildMissingCipher;
  }
  if (markerPresent && !hasKey) {
    return DbUnreadableReason.keyMissing;
  }
  if (sqliteResultCode == sqliteNotADb) {
    return DbUnreadableReason.wrongKeyOrFormat;
  }
  return DbUnreadableReason.corrupt;
}

/// Outcome of probing the DB at startup. [ok] is true when the file opened and
/// a trivial read succeeded; otherwise [reason] and [error] describe why.
class DbProbeResult {
  const DbProbeResult.ok() : ok = true, reason = null, error = null;

  const DbProbeResult.unreadable(this.reason, this.error) : ok = false;

  final bool ok;
  final DbUnreadableReason? reason;

  /// The underlying open failure (typically a `SqliteException`), kept so the
  /// screen can show the technical detail for a bug report.
  final Object? error;

  /// Whether it is safe to offer a "delete local cache" action. False for
  /// [DbUnreadableReason.buildMissingCipher], where the data is intact.
  bool get allowsDelete =>
      !ok && reason != DbUnreadableReason.buildMissingCipher;
}
