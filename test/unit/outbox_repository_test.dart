import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';

import 'db_test_helper.dart';

const _accountId = 'acc-1';

EmailDraft _makeDraft({
  String to = 'bob@example.com',
  String subject = 'Hello',
}) =>
    EmailDraft(
      from: const EmailAddress(name: 'Alice', email: 'alice@example.com'),
      to: [EmailAddress(email: to)],
      cc: const [],
      subject: subject,
      body: 'body',
    );

Future<void> _seedAccount(AppDatabase db) async {
  await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: _accountId,
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          imapPort: 993,
          imapSsl: true,
          smtpHost: 'smtp.example.com',
          smtpPort: 587,
          smtpSsl: true,
        ),
      );
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    // enqueue() reads the app version via package_info_plus to stamp the
    // outgoing User-Agent header; feed it a deterministic value under test.
    configurePackageInfoForTests();
  });

  group('OutboxRepositoryImpl', () {
    test('enqueue inserts a pending row with an envelope', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);

      final id = await repo.enqueue(
        _accountId,
        _makeDraft(subject: 'First'),
      );
      expect(id, isNonZero);

      final rows = await db.select(db.outbox).get();
      expect(rows, hasLength(1));
      expect(rows.first.accountId, _accountId);
      expect(rows.first.status, 'pending');
      expect(rows.first.attempts, 0);
      expect(rows.first.envelopeJson, contains('First'));
      // MIME is pre-rendered so the queued payload doesn't depend on the
      // draft being readable at flush time.
      expect(rows.first.mimeBase64, isNotEmpty);
    });

    test('enqueue stamps a User-Agent header with the app version', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);

      await repo.enqueue(_accountId, _makeDraft());

      final rows = await db.select(db.outbox).get();
      final mime = utf8.decode(base64.decode(rows.first.mimeBase64));
      expect(mime, contains('User-Agent: sharedinbox/$testAppVersion'));
    });

    test(
      'flush passes the decoded draft to the sender and deletes on success',
      () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft(subject: 'Drain me'));

        final seen = <String>[];
        final sent = await repo.flush(_accountId, (job) async {
          seen.add(job.draft.subject);
        });

        expect(sent, 1);
        expect(seen, ['Drain me']);
        final remaining = await db.select(db.outbox).get();
        expect(remaining, isEmpty);
      },
    );

    test(
      'transient failure increments attempts and schedules a backoff',
      () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft());

        final now = DateTime(2026, 1, 1, 12);
        final sent = await repo.flush(
          _accountId,
          (job) async {
            throw Exception('temporary network failure');
          },
          now: now,
        );
        expect(sent, 0);

        final rows = await db.select(db.outbox).get();
        expect(rows, hasLength(1));
        expect(rows.first.attempts, 1);
        expect(rows.first.status, 'pending');
        expect(rows.first.lastError, contains('temporary'));
        // First retry backoff is 30s.
        expect(
          rows.first.nextAttemptAt,
          now.add(const Duration(seconds: 30)),
        );
      },
    );

    test(
      'permanent failure marks row failed and does not schedule a retry',
      () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft());

        final sent = await repo.flush(_accountId, (job) async {
          throw PermanentSendException('rejected by server');
        });
        expect(sent, 0);

        final rows = await db.select(db.outbox).get();
        expect(rows, hasLength(1));
        expect(rows.first.status, 'failed');
        expect(rows.first.lastError, contains('rejected'));
        expect(rows.first.nextAttemptAt, isNull);
      },
    );

    test('flush respects nextAttemptAt — early rows are skipped', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft(subject: 'Wait'));

      final t0 = DateTime(2026, 1, 1, 12);
      // First flush fails so the row is rescheduled.
      await repo.flush(
        _accountId,
        (job) async => throw Exception('boom'),
        now: t0,
      );

      var attempts = 0;
      await repo.flush(
        _accountId,
        (job) async => attempts++,
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(
        attempts,
        0,
        reason: 'row should still be inside the 30s backoff window',
      );
    });

    test('flush picks up rows whose backoff has elapsed', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft(subject: 'Eventually'));

      final t0 = DateTime(2026, 1, 1, 12);
      await repo.flush(
        _accountId,
        (job) async => throw Exception('boom'),
        now: t0,
      );

      var attempts = 0;
      final sent = await repo.flush(
        _accountId,
        (job) async => attempts++,
        now: t0.add(const Duration(seconds: 31)),
      );
      expect(attempts, 1);
      expect(sent, 1);
    });

    test('failed rows are not picked up by an automatic flush', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft());
      await repo.flush(_accountId, (job) async {
        throw PermanentSendException('nope');
      });

      var attempts = 0;
      final sent = await repo.flush(_accountId, (job) async => attempts++);
      expect(attempts, 0);
      expect(sent, 0);

      // ...until the user explicitly hits Retry.
      final rows = await (db.select(db.outbox)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
      await repo.retry(rows.first.id);
      await repo.flush(_accountId, (job) async => attempts++);
      expect(attempts, 1);
    });

    test(
      'resetPendingBackoff makes waiting rows eligible immediately',
      () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft(subject: 'Waiting'));

        // Fail once so the row picks up a nextAttemptAt in the future.
        final t0 = DateTime(2026, 1, 1, 12);
        await repo.flush(
          _accountId,
          (job) async => throw Exception('boom'),
          now: t0,
        );
        final beforeReset = await db.select(db.outbox).get();
        expect(beforeReset.first.nextAttemptAt, isNotNull);
        expect(beforeReset.first.attempts, 1);

        // Simulate reconnect: clear backoff while keeping the attempt counter.
        final cleared = await repo.resetPendingBackoff();
        expect(cleared, 1);

        final afterReset = await db.select(db.outbox).get();
        expect(afterReset.first.nextAttemptAt, isNull);
        expect(
          afterReset.first.attempts,
          1,
          reason: 'attempt counter must be preserved so the next backoff still '
              'ramps if the send fails again',
        );

        // The next flush picks the row up immediately, even 1 second later
        // (well inside the original 30s backoff window).
        final sentSubjects = <String>[];
        final sent = await repo.flush(
          _accountId,
          (job) async => sentSubjects.add(job.draft.subject),
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(sent, 1);
        expect(sentSubjects, ['Waiting']);
      },
    );

    test('resetPendingBackoff ignores failed rows', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft(subject: 'Rejected'));
      await repo.flush(_accountId, (job) async {
        throw PermanentSendException('nope');
      });

      final cleared = await repo.resetPendingBackoff();
      expect(cleared, 0);

      final rows = await db.select(db.outbox).get();
      expect(rows.first.status, 'failed');
    });

    test('discard removes the row', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      final id = await repo.enqueue(_accountId, _makeDraft());

      await repo.discard(id);
      final rows = await db.select(db.outbox).get();
      expect(rows, isEmpty);
    });

    group('OutboxFlushObserver', () {
      test('fires onAttempt + onOk when the send succeeds', () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft(subject: 'Good'));

        final attempts = <int>[];
        final oks = <int>[];
        final transients = <String>[];
        final permanents = <String>[];
        final observer = OutboxFlushObserver(
          onAttempt: (job) => attempts.add(job.id),
          onOk: (job) => oks.add(job.id),
          onTransient: (j, e, __, ___) => transients.add(e.toString()),
          onPermanent: (j, e) => permanents.add(e.toString()),
        );

        await repo.flush(_accountId, (job) async {}, observer: observer);

        expect(attempts, hasLength(1));
        expect(oks, hasLength(1));
        expect(attempts.first, oks.first);
        expect(transients, isEmpty);
        expect(permanents, isEmpty);
      });

      test(
        'fires onAttempt + onTransient with backoff on transient failure',
        () async {
          final db = openTestDatabase();
          await _seedAccount(db);
          final repo = OutboxRepositoryImpl(db);
          await repo.enqueue(_accountId, _makeDraft());

          DateTime? capturedNext;
          Object? capturedErr;
          var attemptCount = 0;
          final observer = OutboxFlushObserver(
            onAttempt: (_) => attemptCount++,
            onTransient: (job, error, stack, nextAttemptAt) {
              capturedErr = error;
              capturedNext = nextAttemptAt;
            },
          );

          final t0 = DateTime(2026, 1, 1, 12);
          await repo.flush(
            _accountId,
            (job) async => throw Exception('boom'),
            now: t0,
            observer: observer,
          );

          expect(attemptCount, 1);
          expect(capturedErr.toString(), contains('boom'));
          expect(capturedNext, t0.add(const Duration(seconds: 30)));
        },
      );

      test(
        'fires onPermanent (not onTransient) on PermanentSendException',
        () async {
          final db = openTestDatabase();
          await _seedAccount(db);
          final repo = OutboxRepositoryImpl(db);
          await repo.enqueue(_accountId, _makeDraft());

          var transientCount = 0;
          PermanentSendException? captured;
          final observer = OutboxFlushObserver(
            onTransient: (_, __, ___, ____) => transientCount++,
            onPermanent: (_, e) => captured = e,
          );

          await repo.flush(
            _accountId,
            (job) async {
              throw PermanentSendException('rejected');
            },
            observer: observer,
          );

          expect(transientCount, 0);
          expect(captured?.message, 'rejected');
        },
      );

      test(
        'observer callbacks that throw are swallowed and do not halt flush',
        () async {
          final db = openTestDatabase();
          await _seedAccount(db);
          final repo = OutboxRepositoryImpl(db);
          await repo.enqueue(_accountId, _makeDraft(subject: 'A'));
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          await repo.enqueue(_accountId, _makeDraft(subject: 'B'));

          final delivered = <String>[];
          final observer = OutboxFlushObserver(
            onAttempt: (_) => throw StateError('logger fell over'),
            onOk: (job) => delivered.add(job.draft.subject),
          );

          final sent = await repo.flush(
            _accountId,
            (job) async {},
            observer: observer,
          );

          expect(sent, 2);
          expect(delivered, ['A', 'B']);
        },
      );
    });

    test('observeOutbox emits the live list', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);

      final stream = repo.observeOutbox(_accountId);
      await expectLater(stream, emits(isEmpty));

      await repo.enqueue(_accountId, _makeDraft(subject: 'Live'));
      await expectLater(
        stream,
        emits(
          predicate<List<OutboxMessage>>(
            (rows) => rows.length == 1 && rows.first.subject == 'Live',
          ),
        ),
      );
    });

    test('observeAllOutbox merges rows from every account by createdAt',
        () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              id: 'acc-2',
              displayName: 'Bob',
              email: 'bob@example.com',
              imapHost: 'imap.example.com',
              imapPort: 993,
              imapSsl: true,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              smtpSsl: true,
            ),
          );
      final repo = OutboxRepositoryImpl(db);

      await repo.enqueue(_accountId, _makeDraft(subject: 'First'));
      // Nudge createdAt forward so ordering is deterministic under the second
      // resolution used by DateTime.now() in enqueue().
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await repo.enqueue('acc-2', _makeDraft(subject: 'Second'));

      final rows = await repo.observeAllOutbox().first;
      expect(rows.map((r) => r.accountId), [_accountId, 'acc-2']);
      expect(rows.map((r) => r.subject), ['First', 'Second']);
    });
  });
}
