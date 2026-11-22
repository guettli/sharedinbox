import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sync/outbox_retry_scheduler.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'recording_app_log_repository.dart';

// A failed send is retried when its retry time comes, also while the IMAP
// loop sits in IDLE: the sync loops drained the outbox only at the start of
// a cycle, so a message stayed queued for up to 25 minutes (#1331). The
// scheduler runs beside the loops and never kicks them, so IDLE is kept.

OutboxMessage _row({
  int id = 1,
  String accountId = 'acc-1',
  DateTime? nextAttemptAt,
  String status = 'pending',
}) =>
    OutboxMessage(
      id: id,
      accountId: accountId,
      subject: 'Hello',
      to: const ['bob@example.com'],
      cc: const [],
      createdAt: DateTime(2026),
      attempts: 1,
      status: status,
      nextAttemptAt: nextAttemptAt,
    );

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  test('drains the account when the retry time comes', () {
    fakeAsync((async) {
      final outbox = StreamController<List<OutboxMessage>>();
      final others = [
        // Not waiting for a retry: left to the sync cycle and the UI.
        _row(id: 2, accountId: 'acc-2'),
        _row(
          id: 3,
          accountId: 'acc-3',
          status: 'failed',
          nextAttemptAt: t0.add(const Duration(seconds: 10)),
        ),
      ];
      final drained = <String>[];
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async {
          drained.add(accountId);
          outbox.add(others); // Sent: the row left the outbox.
        },
        clock: async.getClock(t0).now,
      )..start();

      outbox.add([
        _row(nextAttemptAt: t0.add(const Duration(seconds: 30))),
        ...others,
      ]);
      async.flushMicrotasks();
      expect(scheduler.nextWakeAt, t0.add(const Duration(seconds: 30)));

      async.elapse(const Duration(seconds: 29));
      expect(drained, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(drained, ['acc-1']);

      // Nothing else is due, ever.
      async.elapse(const Duration(hours: 2));
      expect(drained, ['acc-1']);
      scheduler.dispose();
      unawaited(outbox.close());
    });
  });

  test('re-arms for the new retry time after a failed retry', () {
    fakeAsync((async) {
      final outbox = StreamController<List<OutboxMessage>>();
      final clock = async.getClock(t0);
      final drained = <DateTime>[];
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async {
          drained.add(clock.now());
          // The attempt hangs until its timeout, then the row is due 2 min
          // after the failure.
          await Future<void>.delayed(const Duration(seconds: 50));
          outbox.add([
            _row(nextAttemptAt: clock.now().add(const Duration(minutes: 2))),
          ]);
        },
        clock: clock.now,
      )..start();

      outbox.add([_row(nextAttemptAt: t0.add(const Duration(seconds: 30)))]);
      async.elapse(const Duration(seconds: 30));
      expect(drained, [t0.add(const Duration(seconds: 30))]);

      async.elapse(const Duration(seconds: 50));
      final due = t0.add(const Duration(seconds: 80 + 120));
      expect(scheduler.nextWakeAt, due);
      async.elapse(const Duration(minutes: 2));
      expect(drained, [t0.add(const Duration(seconds: 30)), due]);
      scheduler.dispose();
      unawaited(outbox.close());
    });
  });

  test('a drain that throws backs off and logs each error once', () {
    fakeAsync((async) {
      // E.g. a locked keyring: reading the password throws before the flush
      // reaches the row, so its retry time never moves. Retrying every 30 s
      // with two log lines each time would go on forever.
      final outbox = StreamController<List<OutboxMessage>>();
      final clock = async.getClock(t0);
      final logs = RecordingAppLogRepository();
      final drains = <Duration>[];
      var error = 'No password stored';
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async {
          drains.add(clock.now().difference(t0));
          throw StateError(error);
        },
        logger: AppLogger(logs),
        clock: clock.now,
      )..start();
      List<String> failedLogs() => [
            for (final r in logs.rows)
              if (r.event == 'outbox.retry.failed') r.message,
          ];

      outbox.add([_row(nextAttemptAt: t0)]);
      async.elapse(const Duration(hours: 2));
      expect(drains, const [
        Duration.zero,
        Duration(seconds: 30),
        Duration(seconds: 30 + 120),
        Duration(seconds: 30 + 120 + 600),
        Duration(seconds: 30 + 120 + 600 + 3600),
      ]);
      expect(failedLogs(), hasLength(1));

      // Another error is logged once again.
      error = 'Keyring locked';
      async.elapse(const Duration(hours: 1));
      expect(drains, hasLength(6));
      expect(failedLogs(), hasLength(2));
      expect(failedLogs().last, contains('Keyring locked'));

      // The row changed (the user hit "Retry now", or a drain got to it):
      // the backoff starts over.
      outbox.add([
        _row(nextAttemptAt: clock.now().add(const Duration(seconds: 5))),
      ]);
      async.elapse(const Duration(seconds: 5));
      expect(drains, hasLength(7));
      scheduler.dispose();
      unawaited(outbox.close());
    });
  });

  test('a drain that leaves the row due waits minGap, not zero', () {
    fakeAsync((async) {
      // The row was being edited: the drain returned without touching it.
      final outbox = StreamController<List<OutboxMessage>>();
      var drains = 0;
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async => drains++,
        clock: async.getClock(t0).now,
      )..start();

      outbox.add([_row(nextAttemptAt: t0)]);
      async.elapse(const Duration(seconds: 1));
      expect(drains, 1);
      async.elapse(const Duration(seconds: 28));
      expect(drains, 1);
      async.elapse(const Duration(seconds: 1));
      expect(drains, 2);
      scheduler.dispose();
      unawaited(outbox.close());
    });
  });

  test('rearm uses the wall clock after a suspend', () {
    fakeAsync((async) {
      // The timer was armed for 10 min, but the device slept through the
      // retry time: on resume, the retry runs at once.
      final outbox = StreamController<List<OutboxMessage>>();
      var wall = t0;
      var drains = 0;
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async => drains++,
        clock: () => wall,
      )..start();
      outbox.add([_row(nextAttemptAt: t0.add(const Duration(minutes: 10)))]);
      async.flushMicrotasks();

      wall = t0.add(const Duration(hours: 1));
      scheduler.rearm();
      async.elapse(Duration.zero);
      expect(drains, 1);
      scheduler.dispose();
      unawaited(outbox.close());
    });
  });

  test('dispose cancels the armed retry', () {
    fakeAsync((async) {
      final outbox = StreamController<List<OutboxMessage>>();
      var drains = 0;
      final scheduler = OutboxRetryScheduler(
        outbox: outbox.stream,
        drain: (accountId) async => drains++,
        clock: async.getClock(t0).now,
      )..start();
      outbox.add([_row(nextAttemptAt: t0.add(const Duration(seconds: 30)))]);
      async.flushMicrotasks();
      scheduler.dispose();
      async.elapse(const Duration(minutes: 1));
      expect(drains, 0);
      unawaited(outbox.close());
    });
  });

  group('with the real outbox', () {
    late AppDatabase db;
    late OutboxRepositoryImpl repo;

    setUp(() async {
      db = await openTestDatabaseWithAccounts(['acc-1']);
      repo = OutboxRepositoryImpl(db);
    });
    tearDown(() => db.close());

    /// Queues a message that already failed once and is due again in about
    /// a second (the DB stores whole seconds).
    Future<int> queueFailedRow() async {
      final id = await repo.enqueue(
        'acc-1',
        const EmailDraft(
          from: EmailAddress(email: 'alice@example.com'),
          to: [EmailAddress(email: 'bob@example.com')],
          cc: [],
          subject: 'Hello',
          body: 'body',
        ),
      );
      await (db.update(db.outbox)..where((t) => t.id.equals(id))).write(
        OutboxCompanion(
          attempts: const Value(1),
          lastError: const Value('SMTP connect/auth timed out'),
          nextAttemptAt: Value(DateTime.now().add(const Duration(seconds: 1))),
        ),
      );
      return id;
    }

    Future<void> waitFor(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('sends the queued message once its retry time comes', () async {
      await queueFailedRow();
      final sent = <int>[];
      final scheduler = OutboxRetryScheduler(
        outbox: repo.observeAllOutbox(),
        drain: (accountId) =>
            repo.flush(accountId, (job) async => sent.add(job.id)),
      )..start();
      addTearDown(scheduler.dispose);

      await repo.observeAllOutbox().firstWhere((rows) => rows.isEmpty);
      expect(sent, hasLength(1));
    });

    test('a row the foreground send is sending is not sent again', () async {
      final id = await queueFailedRow();
      final sends = <String>[];
      // The foreground send (Compose, Retry now, a sync cycle) holds the row
      // on a slow link while the retry time passes.
      final release = Completer<void>();
      final foreground = repo.flush(
        'acc-1',
        (job) async {
          sends.add('foreground ${job.id}');
          await release.future;
        },
        now: DateTime.now().add(const Duration(seconds: 2)),
      );
      await waitFor(() => sends.isNotEmpty);

      final retries = <Future<int>>[];
      final scheduler = OutboxRetryScheduler(
        outbox: repo.observeAllOutbox(),
        drain: (accountId) {
          final retry = repo.flush(
            accountId,
            (job) async => sends.add('retry ${job.id}'),
          );
          retries.add(retry);
          return retry;
        },
      )..start();
      addTearDown(scheduler.dispose);

      // The retry time passes while the foreground send still holds the row.
      await waitFor(() => retries.isNotEmpty);
      release.complete();
      expect(await foreground, 1);
      expect(await Future.wait(retries), everyElement(0));

      expect(sends, ['foreground $id']);
      expect(await db.select(db.outbox).get(), isEmpty);
    });
  });
}
