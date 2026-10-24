import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:sharedinbox/data/storage/attachment_store.dart';

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

/// Seeds a second IMAP account (`acc-2` / Bob) for the multi-account tests.
Future<void> _seedSecondAccount(AppDatabase db) async {
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
}

void main() {
  setUpAll(configureSqliteForTests);

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
      final repo = OutboxRepositoryImpl(db, appVersion: testAppVersion);

      await repo.enqueue(_accountId, _makeDraft());

      final rows = await db.select(db.outbox).get();
      final mime = utf8.decode(base64.decode(rows.first.mimeBase64));
      expect(mime, contains('User-Agent: sharedinbox/$testAppVersion'));
    });

    test('a reply keeps In-Reply-To and References in MIME and job draft',
        () async {
      // The IMAP/JMAP senders rebuild the message from job.draft, so the
      // reply headers must survive the envelope, not only the stored MIME.
      final (:repo, :mime) = await _enqueueReply(
        inReplyTo: 'parent@example.com',
        references: const ['root@example.com', 'parent@example.com'],
      );
      _expectReplyHeaders(mime);

      EmailDraft? seen;
      await repo.flush(_accountId, (job) async => seen = job.draft);
      expect(seen?.inReplyTo, 'parent@example.com');
      expect(seen?.references, ['root@example.com', 'parent@example.com']);
    });

    test('Bcc survives the outbox envelope (#1126)', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      const draft = EmailDraft(
        from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
        to: [EmailAddress(email: 'bob@example.com')],
        cc: [],
        bcc: [EmailAddress(name: 'Eve', email: 'eve@example.com')],
        subject: 'Hidden',
        body: 'body',
      );
      await repo.enqueue(_accountId, draft);

      // The stored MIME snapshot never carries Bcc; only the envelope does.
      final row = (await db.select(db.outbox).get()).single;
      final mime = utf8.decode(base64.decode(row.mimeBase64));
      expect(mime, isNot(contains(RegExp('^Bcc:', multiLine: true))));
      expect(mime, isNot(contains('eve@example.com')));

      final listed = await repo.observeOutbox(_accountId).first;
      expect(listed.single.bcc, ['eve@example.com']);

      EmailDraft? seen;
      await repo.flush(_accountId, (job) async => seen = job.draft);
      expect(seen?.bcc.single.email, 'eve@example.com');
      expect(seen?.bcc.single.name, 'Eve');
      expect(seen?.allRecipients.map((a) => a.email), [
        'bob@example.com',
        'eve@example.com',
      ]);
    });

    test('a row queued before Bcc existed decodes with no Bcc', () async {
      final db = openTestDatabase();
      await _seedAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft());
      final row = (await db.select(db.outbox).get()).single;
      final env = jsonDecode(row.envelopeJson) as Map<String, dynamic>;
      expect(env, isNot(contains('bcc')));

      EmailDraft? seen;
      await repo.flush(_accountId, (job) async => seen = job.draft);
      expect(seen?.bcc, isEmpty);
    });

    test('a reply with still-bracketed ids does not double the brackets',
        () async {
      final (:repo, :mime) = await _enqueueReply(
        inReplyTo: '<parent@example.com>',
        references: const ['<root@example.com>', 'parent@example.com'],
      );
      _expectReplyHeaders(mime);
      expect(mime, isNot(contains('<<')));
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
      'flush hands the sender the row createdAt so it can time the queue wait',
      () async {
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft());

        // Backdate the queued row so the sender sees a non-trivial wait.
        final queuedAt = DateTime(2026, 1, 1, 9);
        await db.update(db.outbox).write(
              OutboxCompanion(createdAt: Value(queuedAt)),
            );

        DateTime? seenCreatedAt;
        await repo.flush(_accountId, (job) async {
          seenCreatedAt = job.createdAt;
        });

        expect(seenCreatedAt, queuedAt);
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

    test(
      'concurrent flushes for one account serialise so a row is sent once',
      () async {
        // Regression for #755: a UI-initiated send (EmailRepository.sendNow)
        // and the background sync loop can both call flush at the same moment.
        // Without the per-account lock they would each select the same pending
        // row and transmit it — delivering the message twice.
        final db = openTestDatabase();
        await _seedAccount(db);
        final repo = OutboxRepositoryImpl(db);
        await repo.enqueue(_accountId, _makeDraft(subject: 'once'));

        var senderCalls = 0;
        final firstEntered = Completer<void>();
        final release = Completer<void>();
        Future<void> sender(OutboxJob job) async {
          senderCalls++;
          if (!firstEntered.isCompleted) firstEntered.complete();
          // Hold the first flush inside the sender so the second flush would
          // race it if the lock were missing.
          await release.future;
        }

        final flushA = repo.flush(_accountId, sender);
        await firstEntered.future;
        final flushB = repo.flush(_accountId, sender);

        // Give B a chance to (wrongly) pick up the same row before A finishes.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        release.complete();

        final sentA = await flushA;
        final sentB = await flushB;

        expect(
          senderCalls,
          1,
          reason: 'the row must be transmitted exactly once',
        );
        expect(sentA, 1);
        expect(
          sentB,
          0,
          reason: 'B waits for A, by which point the row is already gone',
        );
        expect(await db.select(db.outbox).get(), isEmpty);
      },
    );

    test('flushes for different accounts still run concurrently', () async {
      // The lock is per-account, so an in-flight send for one account must not
      // block a send for another.
      final db = openTestDatabase();
      await _seedAccount(db);
      await _seedSecondAccount(db);
      final repo = OutboxRepositoryImpl(db);
      await repo.enqueue(_accountId, _makeDraft(subject: 'A'));
      await repo.enqueue('acc-2', _makeDraft(subject: 'B'));

      final bothEntered = Completer<void>();
      var entered = 0;
      final release = Completer<void>();
      Future<void> sender(OutboxJob job) async {
        entered++;
        if (entered == 2 && !bothEntered.isCompleted) bothEntered.complete();
        await release.future;
      }

      final flushA = repo.flush(_accountId, sender);
      final flushB = repo.flush('acc-2', sender);

      // Both senders should be inside the send at the same time; if the lock
      // were global this would hang and the test would time out.
      await bothEntered.future;
      release.complete();
      expect(await flushA, 1);
      expect(await flushB, 1);
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
      await _seedSecondAccount(db);
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

  group('attachment copies (#955)', () {
    late AppDatabase db;
    late OutboxRepositoryImpl repo;
    late Directory tmp;
    late Directory storeRoot;
    late File own;
    late File shrunk;

    setUp(() async {
      db = openTestDatabase();
      await _seedAccount(db);
      tmp = await Directory.systemTemp.createTemp('outbox_attachments_test');
      storeRoot = Directory(p.join(tmp.path, 'outbox_attachments'));
      repo = OutboxRepositoryImpl(
        db,
        attachmentStore: AttachmentStore(() async => storeRoot),
      );
      own = File(p.join(tmp.path, 'home', 'own.pdf'));
      await own.create(recursive: true);
      await own.writeAsString('pdf');
      shrunk = File(p.join(tmp.path, 'cache', 'photo.jpg'));
      await shrunk.create(recursive: true);
      await shrunk.writeAsString('jpg');
    });
    tearDown(() => tmp.delete(recursive: true));

    Future<int> enqueue(List<String> paths) => repo.enqueue(
          _accountId,
          EmailDraft(
            from: const EmailAddress(email: 'alice@example.com'),
            to: const [EmailAddress(email: 'bob@example.com')],
            cc: const [],
            subject: 's',
            body: 'b',
            attachmentFilePaths: paths,
          ),
        );

    Directory folderOf(int id) => Directory(p.join(storeRoot.path, '$id'));

    test('enqueue sends from its own copies, so the caller may delete them',
        () async {
      final id = await enqueue([own.path, shrunk.path]);
      // What compose does when it closes, and a sent draft's folder.
      await shrunk.delete();

      final sent = <List<String>>[];
      await repo.flush(_accountId, (job) async {
        sent.add(job.draft.attachmentFilePaths);
        for (final path in job.draft.attachmentFilePaths) {
          expect(await File(path).exists(), isTrue, reason: path);
        }
      });

      final paths = sent.single;
      expect(paths.map(p.basename), ['own.pdf', 'photo.jpg']);
      expect(paths.every((x) => p.isWithin(folderOf(id).path, x)), isTrue);
      // Sent: the copies go with the row; the user's file stays.
      expect(await folderOf(id).exists(), isFalse);
      expect(await own.exists(), isTrue);
    });

    test('a file already gone keeps its path, so the send fails loudly',
        () async {
      final gone = p.join(tmp.path, 'gone.png');
      await enqueue([gone]);
      final row = (await db.select(db.outbox).get()).single;
      expect(jsonDecode(row.attachmentsJson), [gone]);
    });

    test('the copies stay while the message is still queued', () async {
      final id = await enqueue([own.path]);
      await repo.flush(_accountId, (_) async => throw Exception('offline'));
      await repo.flush(
        _accountId,
        (_) async => throw PermanentSendException('5.1.2'),
        now: DateTime.now().add(const Duration(days: 1)),
      );
      expect(await folderOf(id).exists(), isTrue);
    });

    test('discard deletes the copies', () async {
      final id = await enqueue([own.path]);
      await repo.discard(id);
      expect(await folderOf(id).exists(), isFalse);
      expect(await own.exists(), isTrue);
    });

    test('takeForEdit hands the copies over, then deletes them', () async {
      final id = await enqueue([own.path]);
      String? content;
      await repo.takeForEdit(id, (job) async {
        // The hand-off (saving a draft) copies them while they exist.
        content =
            await File(job.draft.attachmentFilePaths.single).readAsString();
      });
      expect(content, 'pdf');
      expect(await folderOf(id).exists(), isFalse);
    });

    test('a failed takeForEdit keeps the copies with the queued row', () async {
      final id = await enqueue([own.path]);
      await expectLater(
        repo.takeForEdit<void>(id, (_) => throw StateError('disk full')),
        throwsStateError,
      );
      expect(await folderOf(id).exists(), isTrue);
    });

    test('deleteOrphanedAttachments removes folders of gone rows only',
        () async {
      final id = await enqueue([own.path]);
      final orphan = Directory(p.join(storeRoot.path, '${id + 100}'));
      await orphan.create(recursive: true);

      await repo.deleteOrphanedAttachments();

      expect(await orphan.exists(), isFalse);
      expect(await folderOf(id).exists(), isTrue);
    });
  });

  group('takeForEdit', () {
    late AppDatabase db;
    late OutboxRepositoryImpl repo;

    setUp(() async {
      db = openTestDatabase();
      await _seedAccount(db);
      repo = OutboxRepositoryImpl(db);
    });

    Future<int> enqueueFull() => repo.enqueue(
          _accountId,
          const EmailDraft(
            from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
            to: [EmailAddress(name: 'Carol', email: 'carol@example.com')],
            cc: [EmailAddress(email: 'dave@example.com')],
            bcc: [EmailAddress(email: 'erin@example.com')],
            subject: 'Typo',
            body: 'Hi Carol',
            attachmentFilePaths: ['/tmp/a.pdf'],
            inReplyTo: 'parent@example.com',
            references: ['root@example.com', 'parent@example.com'],
          ),
        );

    test('hands off the whole message, then removes the row', () async {
      final id = await enqueueFull();

      final result = await repo.takeForEdit(id, (job) async {
        // Still queued while the hand-off runs.
        expect(await db.select(db.outbox).get(), hasLength(1));
        return job.draft;
      });

      expect(result, isNotNull);
      final draft = result!;
      expect(draft.to.single.name, 'Carol');
      expect(draft.to.single.email, 'carol@example.com');
      expect(draft.cc.single.email, 'dave@example.com');
      expect(draft.bcc.single.email, 'erin@example.com');
      expect(draft.subject, 'Typo');
      expect(draft.body, 'Hi Carol');
      expect(draft.attachmentFilePaths, ['/tmp/a.pdf']);
      expect(draft.inReplyTo, 'parent@example.com');
      expect(draft.references, ['root@example.com', 'parent@example.com']);
      expect(await db.select(db.outbox).get(), isEmpty);
    });

    test('a failed hand-off leaves the message queued', () async {
      final id = await enqueueFull();

      await expectLater(
        repo.takeForEdit<void>(id, (_) => throw StateError('disk full')),
        throwsStateError,
      );

      expect(await db.select(db.outbox).get(), hasLength(1));
    });

    test('returns null for a row that is gone', () async {
      var called = false;
      final result = await repo.takeForEdit(999, (_) async => called = true);
      expect(result, isNull);
      expect(called, isFalse);
    });

    test('refuses a row the flush is sending right now', () async {
      final id = await enqueueFull();
      final entered = Completer<void>();
      final release = Completer<void>();
      final flush = repo.flush(_accountId, (job) async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      await expectLater(
        repo.takeForEdit(id, (job) async => job),
        throwsA(isA<OutboxRowInFlightException>()),
      );

      release.complete();
      expect(await flush, 1);
      expect(await db.select(db.outbox).get(), isEmpty);
    });

    test('a row taken while the flush sends an earlier one is not sent',
        () async {
      await repo.enqueue(_accountId, _makeDraft(subject: 'first'));
      final second = await repo.enqueue(
        _accountId,
        _makeDraft(subject: 'second'),
      );
      final sentSubjects = <String>[];
      final entered = Completer<void>();
      final release = Completer<void>();
      final flush = repo.flush(_accountId, (job) async {
        sentSubjects.add(job.draft.subject);
        if (!entered.isCompleted) entered.complete();
        await release.future;
      });
      await entered.future;

      // The flush already selected both rows; "second" waits its turn.
      final taken = await repo.takeForEdit(second, (job) async => job);
      expect(taken?.draft.subject, 'second');

      release.complete();
      expect(await flush, 1);
      expect(sentSubjects, ['first']);
      expect(await db.select(db.outbox).get(), isEmpty);
    });

    test('a flush starting during the hand-off does not send the row',
        () async {
      final id = await enqueueFull();
      final inHandOff = Completer<void>();
      final release = Completer<void>();
      final take = repo.takeForEdit(id, (job) async {
        inHandOff.complete();
        await release.future;
        return job;
      });
      await inHandOff.future;

      var sent = 0;
      final flush = repo.flush(_accountId, (job) async => sent++);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();

      expect(await take, isNotNull);
      expect(await flush, 0);
      expect(sent, 0);
      expect(await db.select(db.outbox).get(), isEmpty);
    });
  });
}

/// Enqueues a reply to `parent@example.com` with the given header ids and
/// returns the repository plus the stored MIME text.
Future<({OutboxRepositoryImpl repo, String mime})> _enqueueReply({
  required String inReplyTo,
  required List<String> references,
}) async {
  final db = openTestDatabase();
  await _seedAccount(db);
  final repo = OutboxRepositoryImpl(db);
  final base = _makeDraft(subject: 'Re: Hello');
  await repo.enqueue(
    _accountId,
    EmailDraft(
      from: base.from,
      to: base.to,
      cc: base.cc,
      subject: base.subject,
      body: base.body,
      inReplyTo: inReplyTo,
      references: references,
    ),
  );
  final rows = await db.select(db.outbox).get();
  return (repo: repo, mime: utf8.decode(base64.decode(rows.first.mimeBase64)));
}

/// The bracketed reply headers every [_enqueueReply] case must produce.
void _expectReplyHeaders(String mime) {
  expect(mime, contains('In-Reply-To: <parent@example.com>'));
  expect(
    mime,
    contains('References: <root@example.com> <parent@example.com>'),
  );
}
