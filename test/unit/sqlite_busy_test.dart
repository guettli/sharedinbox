// SQLITE_BUSY between the app and the WorkManager isolate (#1317, SYNC.md
// "Two writers: SQLITE_BUSY"). Both open the same database file; SQLite
// lets one connection write at a time. These tests hold the write lock
// from another isolate (as the other side would during a long write
// transaction) on a real file-backed database with the production pragmas
// (busy_timeout 5 s, WAL), and measure what a write on the other connection
// does: first with the statements drift sends on its own (the behaviour
// before #1317), then through AppDatabase.

@Timeout(Duration(seconds: 90))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/storage/database_busy.dart';
import 'package:sharedinbox/data/db/busy_retry.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException, sqlite3;

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';

const _busyTimeout = Duration(seconds: 5);

/// Longer than busy_timeout: what a build that honours it would fail.
/// Only one test needs it; the others hold the lock for [_hold].
const _longHold = Duration(seconds: 7);

/// Long enough for writes to meet the held lock (they fail after ~50 ms).
const _hold = Duration(seconds: 1);

const _write = "UPDATE accounts SET display_name = 'x' WHERE id = 'acc-1'";

/// Not idempotent: a second run adds a second row.
const _insert =
    "INSERT INTO search_history_entries (query, searched_at) VALUES ('q', 1)";

/// Prints a measurement, so the run's log carries the numbers.
void _measured(String what, Duration took, [Object? outcome]) =>
    // ignore: avoid_print
    print('measured: $what: ${took.inMilliseconds} ms'
        '${outcome == null ? '' : ' -> $outcome'}');

/// Holds SQLite's write lock on [path] from its own isolate (a raw
/// connection with the production pragmas) for [hold], like the other
/// isolate's long write transaction. [locked] completes once it holds it,
/// [released] once it committed.
class _LockHolder {
  _LockHolder._(this.released);

  final Future<void> released;

  static Future<_LockHolder> start(String path, Duration hold) async {
    final ready = ReceivePort();
    final exit = ReceivePort();
    await Isolate.spawn(
      _holdLock,
      (path, hold.inMilliseconds, ready.sendPort),
      onExit: exit.sendPort,
    );
    await ready.first;
    return _LockHolder._(exit.first.then((_) {}));
  }
}

void _holdLock((String, int, SendPort) args) {
  final (path, holdMs, ready) = args;
  final db = sqlite3.open(path);
  setupPragmasForTesting(db);
  db
    ..execute('BEGIN IMMEDIATE')
    ..execute(_write);
  ready.send(true);
  sleep(Duration(milliseconds: holdMs));
  db
    ..execute('COMMIT')
    ..close();
}

/// Runs [statements] on a raw connection to [path] in its own isolate, as
/// drift would send them before #1317 (a transaction starts with a deferred
/// `BEGIN TRANSACTION`). Returns the time taken and the SQLite extended
/// result code it failed with (null: it succeeded).
Future<(Duration, int?)> _rawWrite(String path, List<String> statements) =>
    Isolate.run(() {
      final db = sqlite3.open(path);
      setupPragmasForTesting(db);
      final watch = Stopwatch()..start();
      try {
        for (final sql in statements) {
          if (sql.startsWith('SELECT')) {
            db.select(sql);
            continue;
          }
          db.execute(sql);
        }
        return (watch.elapsed, null);
      } on SqliteException catch (e) {
        if (!db.autocommit) db.execute('ROLLBACK');
        return (watch.elapsed, e.extendedResultCode);
      } finally {
        db.close();
      }
    });

/// The app's connection, as in production: drift on its own isolate.
AppDatabase _openApp(String path) => AppDatabase(
      NativeDatabase.createInBackground(
        File(path),
        setup: setupPragmasForTesting,
      ),
    );

Future<List<AppLogRow>> _busyLogs(AppDatabase db) =>
    (db.select(db.appLogs)..where((t) => t.event.like('db.busy%'))).get();

/// The busy log lines, once one is written (it is written in the
/// background, once the lock is free).
Future<List<AppLogRow>> _awaitBusyLogs(AppDatabase db) async {
  for (var i = 0; i < 100; i++) {
    final logs = await _busyLogs(db);
    if (logs.isNotEmpty) return logs;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _busyLogs(db);
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory dir;
  late String path;
  late AppDatabase app;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sqlite_busy');
    path = p.join(dir.path, 'app.sqlite');
    app = _openApp(path);
    await seedAccountRow(app, 'acc-1');
  });
  tearDown(() async {
    await app.close();
    dir.deleteSync(recursive: true);
  });

  group('retryOnBusy', () {
    SqliteException busy([int code = 5]) => SqliteException(
          extendedResultCode: code,
          message: 'database is locked',
        );
    const quick = BusyRetryPolicy(
      firstBackoff: Duration(milliseconds: 1),
      maxBackoff: Duration(milliseconds: 4),
    );

    test('recognises SQLITE_BUSY, also rethrown as text', () {
      expect(isSqliteBusy(busy()), isTrue);
      expect(isSqliteBusy(busy(517)), isTrue, reason: 'BUSY_SNAPSHOT');
      expect(
        isSqliteBusy(busy(6)),
        isFalse,
        reason: 'LOCKED: a conflict within the connection, waiting does not '
            'clear it',
      );
      expect(
        isSqliteBusy(
          Exception('DriftRemoteException: SqliteException(261): while '
              'executing, database is locked'),
        ),
        isTrue,
      );
      expect(isSqliteBusy(busy(19)), isFalse, reason: 'CONSTRAINT');
      expect(isSqliteBusy(StateError('x')), isFalse);
      expect(
        isSqliteBusy(
          DatabaseBusyException(
            waited: Duration.zero,
            attempts: 1,
            cause: busy(),
          ),
        ),
        isFalse,
        reason: 'already given up',
      );
    });

    test('tries again while busy and reports the retry', () async {
      final outcomes = <BusyOutcome>[];
      var calls = 0;
      final result = await retryOnBusy(
        () async {
          if (++calls < 3) throw busy();
          return 'ok';
        },
        what: 'statement',
        policy: quick,
        report: outcomes.add,
      );
      expect(result, 'ok');
      expect(calls, 3);
      expect(outcomes.single.attempts, 3);
      expect(outcomes.single.failed, isFalse);
    });

    test('passes other errors on at once', () async {
      var calls = 0;
      await expectLater(
        retryOnBusy<void>(
          () async {
            calls++;
            throw StateError('boom');
          },
          what: 'statement',
          policy: quick,
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });

    test('gives up after the budget with DatabaseBusyException', () async {
      final outcomes = <BusyOutcome>[];
      await expectLater(
        retryOnBusy<void>(
          () async => throw busy(),
          what: 'transaction',
          policy: const BusyRetryPolicy(
            budget: Duration(milliseconds: 30),
            firstBackoff: Duration(milliseconds: 5),
            maxBackoff: Duration(milliseconds: 5),
          ),
          report: outcomes.add,
        ),
        throwsA(isA<DatabaseBusyException>()),
      );
      expect(outcomes.single.failed, isTrue);
      expect(outcomes.single.attempts, greaterThan(1));
    });

    test('does not retry what retryable refuses', () async {
      var calls = 0;
      await expectLater(
        retryOnBusy<void>(
          () async {
            calls++;
            throw busy();
          },
          what: 'transaction',
          retryable: (_) => false,
          policy: quick,
        ),
        throwsA(isA<DatabaseBusyException>()),
      );
      expect(calls, 1);
    });

    test(
        'a transaction that fails busy after it took the lock is not run '
        'again, and nothing of it is applied', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      db.busyRetryPolicy = quick;
      var runs = 0;
      await expectLater(
        db.transaction(() async {
          runs++;
          await db.customStatement(_insert);
          throw busy();
        }),
        throwsA(isA<DatabaseBusyException>()),
      );
      expect(runs, 1);
      expect(
        await db.select(db.searchHistoryEntries).get(),
        isEmpty,
        reason: 'rolled back',
      );
    });

    test('a nested transaction runs in the outer one', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      await db.transaction(() async {
        await db.customStatement(_insert);
        await db.transaction(() => db.customStatement(_insert));
      });
      expect(await db.select(db.searchHistoryEntries).get(), hasLength(2));
    });
  });

  group('before #1317: drift on its own, busy_timeout set to 5 s', () {
    test(
        'a write outside a transaction fails while the lock is held; '
        'busy_timeout does not make it wait for the lock', () async {
      final holder = await _LockHolder.start(path, _hold);
      final (took, code) = await _rawWrite(path, [_write]);
      _measured('autocommit write, lock held 1 s', took, code);
      await holder.released;

      expect(code! & 0xFF, 5, reason: 'SQLITE_BUSY');
      // Measured: about 60 ms, although the lock was free after 1 s and
      // busy_timeout is 5 s. The bundled SQLCipher build lacks HAVE_USLEEP
      // (PRAGMA compile_options), and its busy handler gives up almost at
      // once.
      expect(took, lessThan(_hold));
    });

    test(
        'a transaction that reads before it writes fails at once, '
        'although the lock is free 1.5 s later', () async {
      final holder =
          await _LockHolder.start(path, const Duration(milliseconds: 1500));
      final (took, code) = await _rawWrite(path, [
        'BEGIN TRANSACTION',
        'SELECT count(*) FROM emails',
        _write,
        'COMMIT TRANSACTION',
      ]);
      _measured('read-then-write transaction, lock held 1.5 s', took, code);
      await holder.released;

      expect(code! & 0xFF, 5, reason: 'SQLITE_BUSY, busy_timeout unused');
      expect(took, lessThan(const Duration(milliseconds: 500)));
    });

    test(
        'a transaction that read before another connection committed '
        'fails at its first write (stale snapshot)', () {
      final a = sqlite3.open(path);
      final b = sqlite3.open(path);
      setupPragmasForTesting(a);
      setupPragmasForTesting(b);
      addTearDown(a.close);
      addTearDown(b.close);

      b
        ..execute('BEGIN TRANSACTION')
        ..select('SELECT count(*) FROM emails');
      a.execute(_write); // A short write, done before b writes.
      final watch = Stopwatch()..start();
      final error = () {
        try {
          b.execute(_write);
          return null;
        } on SqliteException catch (e) {
          return e;
        }
      }();
      _measured(
        'stale snapshot write',
        watch.elapsed,
        error?.extendedResultCode,
      );
      b.execute('ROLLBACK');

      expect(error?.extendedResultCode, 517, reason: 'SQLITE_BUSY_SNAPSHOT');
    });
  });

  group('AppDatabase', () {
    test(
        'a transaction that reads before it writes waits for the lock '
        'instead of failing', () async {
      final holder =
          await _LockHolder.start(path, const Duration(milliseconds: 1500));
      final watch = Stopwatch()..start();
      await app.transaction(() async {
        await app.customSelect('SELECT count(*) FROM emails').get();
        await app.customStatement(_write);
      });
      _measured('read-then-write transaction, lock held 1.5 s', watch.elapsed);
      await holder.released;
      expect(watch.elapsed, lessThan(_busyTimeout));
    });

    test(
        'a transaction that read before another connection committed '
        'still writes', () async {
      final other = _openApp(path);
      addTearDown(other.close);
      await other.customSelect('SELECT 1').get(); // Opened.
      late Future<void> otherWrite;
      await app.transaction(() async {
        await app.customSelect('SELECT count(*) FROM emails').get();
        // The other connection writes now. Before #1317 it committed while
        // this one waited, and this one's write failed (BUSY_SNAPSHOT); now
        // it waits for this transaction, which took the write lock first.
        otherWrite = other.customStatement(_write);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await app.customStatement(_insert);
      });
      await otherWrite;
      expect(await app.select(app.searchHistoryEntries).get(), hasLength(1));
    });

    test(
        'a transaction held up longer than busy_timeout is retried and '
        'lands once, with an App Log warn', () async {
      var runs = 0;
      final holder = await _LockHolder.start(path, _longHold);
      final watch = Stopwatch()..start();
      await app.transaction(() async {
        runs++;
        await app.customSelect('SELECT count(*) FROM emails').get();
        await app.customStatement(_insert);
      });
      _measured('transaction, lock held 7 s', watch.elapsed);
      await holder.released;

      expect(runs, 1);
      expect(await app.select(app.searchHistoryEntries).get(), hasLength(1));
      final logs = await _awaitBusyLogs(app);
      expect(logs.single.event, 'db.busy_retried');
      expect(logs.single.level, 'warn');
      expect(logs.single.dataJson, contains('"waitedMs"'));
    });

    test('a write outside a transaction is retried and lands', () async {
      final holder = await _LockHolder.start(path, _hold);
      final watch = Stopwatch()..start();
      await app.customStatement(_insert);
      _measured('autocommit write, lock held 1 s', watch.elapsed);
      await holder.released;

      expect(await app.select(app.searchHistoryEntries).get(), hasLength(1));
      expect((await _awaitBusyLogs(app)).single.event, 'db.busy_retried');
    });

    test(
        'a write that stays busy past the budget fails with '
        'DatabaseBusyException and an App Log error', () async {
      app.busyRetryPolicy = const BusyRetryPolicy(budget: Duration(seconds: 1));
      var runs = 0;
      final holder =
          await _LockHolder.start(path, const Duration(milliseconds: 2500));
      final watch = Stopwatch()..start();
      await expectLater(
        app.transaction(() async => runs++),
        throwsA(
          isA<DatabaseBusyException>()
              .having((e) => e.message, 'message', contains('not saved')),
        ),
      );
      _measured('transaction giving up, budget 1 s', watch.elapsed);
      await holder.released;

      expect(runs, 0, reason: 'the body never ran');
      final log = (await _awaitBusyLogs(app)).single;
      expect(log.event, 'db.busy_failed');
      expect(log.level, 'error');
    });
  });

  group('user actions under contention', () {
    test('star, read, move, delete, snooze and send land', () async {
      final rigPath = p.join(dir.path, 'rig.sqlite');
      final db = _openApp(rigPath);
      addTearDown(db.close);
      final rig = await StatefulImapRig.open(
        StatefulFakeImapServer(
          uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Snoozed': 33},
        )
          ..deliver('INBOX', 'a@test')
          ..deliver('INBOX', 'b@test')
          ..deliver('INBOX', 'c@test')
          ..deliver('INBOX', 'd@test'),
        folders: [
          ('INBOX', 'inbox'),
          ('Archive', 'archive'),
          ('Snoozed', 'snoozed'),
        ],
        database: db,
      );
      Future<Email> row(String messageId) async =>
          (await db.select(db.emails).get())
              .singleWhere((e) => e.messageId == messageId);
      final a = await row('a@test');
      final b = await row('b@test');
      final c = await row('c@test');
      final d = await row('d@test');
      final until = DateTime.now().add(const Duration(days: 1));

      final holder = await _LockHolder.start(rigPath, _hold);
      final watch = Stopwatch()..start();
      await Future.wait([
        rig.emails.setFlag(a.id, seen: true, flagged: true),
        rig.emails.moveEmail(b.id, 'Archive'),
        rig.emails.deleteEmail(c.id),
        rig.emails.snoozeEmail(d.id, until),
        OutboxRepositoryImpl(db).enqueue(
          'acc-1',
          const model.EmailDraft(
            from: model.EmailAddress(email: 'alice@example.com'),
            to: [model.EmailAddress(email: 'bob@example.com')],
            cc: [],
            subject: 'Hello',
            body: 'body',
          ),
        ),
      ]);
      _measured('five user actions, lock held 1 s', watch.elapsed);
      await holder.released;

      expect((await row('a@test')).isSeen, isTrue);
      expect((await row('a@test')).isFlagged, isTrue);
      expect((await row('b@test')).mailboxPath, 'Archive');
      expect((await row('c@test')).mailboxPath, isNot('INBOX'));
      expect((await row('d@test')).snoozedUntil, isNotNull);
      final ops = await db.select(db.pendingChanges).get();
      expect(
        ops.map((o) => o.changeType),
        containsAll(['flag_seen', 'flag_flagged', 'move', 'delete', 'snooze']),
      );
      expect(await db.select(db.outbox).get(), hasLength(1));
      expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
    });
  });
}
