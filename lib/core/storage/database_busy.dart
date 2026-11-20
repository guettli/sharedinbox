/// A write gave up because another connection to the database (the
/// WorkManager background sync, or the app while the background sync runs)
/// held SQLite's write lock for longer than the retry budget
/// (`lib/data/db/busy_retry.dart`). Nothing of the write was stored: a
/// transaction is rolled back as a whole.
///
/// [message] is meant for the user; the UI shows it instead of the raw
/// `SqliteException` (main.dart).
class DatabaseBusyException implements Exception {
  DatabaseBusyException({
    required this.waited,
    required this.attempts,
    required this.cause,
  });

  /// How long the write waited for the lock, over all its attempts.
  final Duration waited;

  /// How many times the write was tried.
  final int attempts;

  /// The last SQLITE_BUSY error.
  final Object cause;

  String get message => 'The change was not saved: the mail database was '
      'busy (a background sync was writing). Please try again.';

  @override
  String toString() =>
      'DatabaseBusyException: $message (attempts: $attempts, cause: $cause)';
}
