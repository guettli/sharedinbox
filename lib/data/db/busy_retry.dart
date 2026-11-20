import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/storage/database_busy.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

// SQLite's write lock is shared by the app and the WorkManager isolate
// (issue #1317, SYNC.md "Two writers: SQLITE_BUSY"). Two parts keep a write
// from failing on it:
//
//  * every write transaction takes the lock with its first statement
//    ([AppDatabase.transaction]), so SQLITE_BUSY can only come before the
//    transaction's body ran (and no stale read snapshot can fail a later
//    write): retrying it then runs the body exactly once;
//  * that attempt, and every write outside a transaction
//    ([BusyRetryInterceptor]), is tried again with backoff ([retryOnBusy])
//    while the other connection holds the lock, up to [BusyRetryPolicy.budget].

/// SQLite primary result codes SQLITE_BUSY and SQLITE_LOCKED.
const _sqliteBusy = 5;
const _sqliteLocked = 6;

final _sqliteCode = RegExp(r'SqliteException\((\d+)\)');

/// True when [error] is SQLite refusing a statement because another
/// connection holds a lock (SQLITE_BUSY, also BUSY_SNAPSHOT and
/// BUSY_RECOVERY, or SQLITE_LOCKED). Matches the text too, so it also holds
/// for the copy a background-isolate connection rethrows
/// (`DriftRemoteException`).
bool isSqliteBusy(Object error) {
  if (error is DatabaseBusyException) return false;
  if (error is SqliteException) return _isBusyCode(error.resultCode);
  final text = error.toString();
  final code = _sqliteCode.firstMatch(text);
  if (code != null) return _isBusyCode(int.parse(code.group(1)!) & 0xFF);
  return text.contains('database is locked') ||
      text.contains('database table is locked');
}

bool _isBusyCode(int primary) =>
    primary == _sqliteBusy || primary == _sqliteLocked;

/// How long a write keeps trying while the database is busy. busy_timeout
/// (5 s, database.dart) is set, but the bundled SQLCipher build (no
/// HAVE_USLEEP) gives up after about 50 ms (measured in
/// test/unit/sqlite_busy_test.dart), so the waiting happens here.
class BusyRetryPolicy {
  const BusyRetryPolicy({
    this.budget = const Duration(seconds: 60),
    this.firstBackoff = const Duration(milliseconds: 50),
    this.maxBackoff = const Duration(milliseconds: 500),
  });

  /// Total time, from the first attempt, after which the write gives up
  /// with [DatabaseBusyException].
  final Duration budget;

  /// Pause before the second attempt; doubles up to [maxBackoff]. Between
  /// attempts the connection is free for other queries (the app's lists).
  final Duration firstBackoff;
  final Duration maxBackoff;
}

/// A write that met a busy database: retried and landed ([failed] false) or
/// gave up ([failed] true). [waited] runs from the first attempt.
class BusyOutcome {
  const BusyOutcome({
    required this.what,
    required this.attempts,
    required this.waited,
    required this.failed,
    this.error,
  });

  /// `transaction` or `statement`.
  final String what;
  final int attempts;
  final Duration waited;
  final bool failed;
  final Object? error;
}

/// Runs [attempt] and runs it again, with backoff, while it fails with
/// SQLITE_BUSY ([isSqliteBusy]) and [retryable] allows it, for at most
/// [policy]'s budget. [report] hears of a write that needed a retry or gave
/// up. A busy failure that is not retried ends in [DatabaseBusyException]
/// (with the original stack trace); any other error passes unchanged.
///
/// Only for an [attempt] that leaves nothing behind when it fails busy: a
/// single statement, or a transaction that failed before its body ran.
Future<T> retryOnBusy<T>(
  Future<T> Function() attempt, {
  required String what,
  bool Function(Object error)? retryable,
  BusyRetryPolicy policy = const BusyRetryPolicy(),
  void Function(BusyOutcome outcome)? report,
}) async {
  final watch = Stopwatch()..start();
  var attempts = 0;
  var backoff = policy.firstBackoff;
  while (true) {
    attempts++;
    try {
      final result = await attempt();
      if (attempts > 1) {
        report?.call(
          BusyOutcome(
            what: what,
            attempts: attempts,
            waited: watch.elapsed,
            failed: false,
          ),
        );
      }
      return result;
    } catch (e, st) {
      if (!isSqliteBusy(e)) rethrow;
      final again = retryable?.call(e) ?? true;
      if (!again || watch.elapsed + backoff > policy.budget) {
        report?.call(
          BusyOutcome(
            what: what,
            attempts: attempts,
            waited: watch.elapsed,
            failed: true,
            error: e,
          ),
        );
        Error.throwWithStackTrace(
          DatabaseBusyException(
            waited: watch.elapsed,
            attempts: attempts,
            cause: e,
          ),
          st,
        );
      }
      await Future<void>.delayed(backoff);
      final next = backoff * 2;
      backoff = next > policy.maxBackoff ? policy.maxBackoff : next;
    }
  }
}

/// Retries a statement that runs outside a transaction (autocommit) when
/// the database is busy: it is atomic, so a failed one left nothing behind.
/// Statements inside a transaction pass through: [AppDatabase.transaction]
/// retries the transaction as a whole. So do batches (not atomic outside a
/// transaction; [AppDatabase.batch] runs them in one). A write of the App
/// Log is retried without a report (the report itself writes there).
class BusyRetryInterceptor extends QueryInterceptor {
  BusyRetryInterceptor();

  BusyRetryPolicy policy = const BusyRetryPolicy();
  void Function(BusyOutcome outcome)? report;

  Future<R> _run<R>(
    QueryExecutor executor,
    String statement,
    Future<R> Function() run,
  ) {
    if (executor is TransactionExecutor) return run();
    // The App Log's own writes are retried with the default budget (a
    // `db.busy_failed` line is written once the lock is free) and not
    // reported: the report writes there.
    final appLog = statement.contains('"app_logs"');
    return retryOnBusy(
      run,
      what: 'statement',
      policy: appLog ? const BusyRetryPolicy() : policy,
      report: appLog ? null : report,
    );
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(executor, statement, () => executor.runCustom(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(executor, statement, () => executor.runInsert(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(executor, statement, () => executor.runUpdate(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(executor, statement, () => executor.runDelete(statement, args));

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(executor, statement, () => executor.runSelect(statement, args));
}
