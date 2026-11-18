// Rows that wait for their server copy (SYNC-REDESIGN.md §6, §4.5, phase
// 4b): a JMAP mail whose server id is unknown gets parked changes, and an
// acked IMAP move whose new location the server never named keeps showing
// the mail in its destination until that folder's sync stores it; either is
// then filled in place by the stored copy, keeping its id.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/db/keyword_fold.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'helpers/offline_repos.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late EmailRepositoryImpl emails;
  late EmailStateWriter writer;
  var now = DateTime.utc(2026, 11, 18, 12);

  setUp(() async {
    now = DateTime.now().toUtc();
    db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    emails = offlineEmailRepository(db, accounts, now: () => now);
    writer = EmailStateWriter(db, now: () => now);
    await accounts.addAccount(aliceImap('acc-1'), 'pw');
    await accounts.addAccount(aliceJmap('jmap-1'), 'pw');
  });
  tearDown(() => db.close());

  Future<List<PendingChangeRow>> ops() =>
      (db.select(db.pendingChanges)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
  Future<Email?> row(String id) =>
      (db.select(db.emails)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> expectConsistent() async =>
      expect(await writer.consistencyProblems(), isEmpty);

  group('a JMAP mail whose server id is unknown', () {
    /// Sync stores the server copy (id `e7`) and matches it.
    Future<void> storeServerCopyAndMatch() async {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:new',
              accountId: 'jmap-1',
              mailboxPath: 'mbox-in',
              uid: 0,
              receivedAt: DateTime(2024),
              messageId: const Value('m1@example.com'),
              srvJmapId: const Value('e7'),
            ),
          );
      await emails.matchArrivalForTest(
        'jmap-1',
        'mbox-in',
        'jmap-1:new',
        'm1@example.com',
      );
    }

    setUp(() async {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:old',
              accountId: 'jmap-1',
              mailboxPath: 'mbox-in',
              uid: 0,
              receivedAt: DateTime(2024),
              messageId: const Value('m1@example.com'),
            ),
          );
    });

    test('gets parked changes: shown, not sent', () async {
      await emails.setFlag('jmap-1:old', flagged: true);

      final op = (await ops()).single;
      expect(op.state, 'parked');
      expect((await row('jmap-1:old'))!.isFlagged, isTrue);
      expect(
        (await row('jmap-1:old'))!.srvIsFlagged,
        isFalse,
        reason: 'the server value is not written',
      );
      expect(await emails.flushPendingChanges('jmap-1', 'pw'), 0);
      await expectConsistent();
    });

    test('is filled in place by the stored copy; its change is sent then',
        () async {
      await emails.setFlag('jmap-1:old', flagged: true);
      await storeServerCopyAndMatch();

      expect(await row('jmap-1:new'), isNull);
      final kept = (await row('jmap-1:old'))!;
      expect(kept.srvJmapId, 'e7');
      expect(kept.isFlagged, isTrue);
      final op = (await ops()).single;
      expect(op.state, 'pending');
      expect((jsonDecode(op.payload) as Map)['jmapId'], 'e7');
      await expectConsistent();
    });

    test('its parked change fails after 7 days; the row stays', () async {
      await emails.setFlag('jmap-1:old', flagged: true);

      now = now.add(const Duration(days: 8));
      await writer.expireParked('jmap-1', folder: 'mbox-in', role: 'inbox');

      final op = (await ops()).single;
      expect(op.state, 'failed');
      expect(op.lastError, contains('server id'));
      final kept = (await row('jmap-1:old'))!;
      expect(kept.isFlagged, isFalse, reason: 'a failed change stops folding');
      await expectConsistent();
    });

    Future<PendingChangeRow> expiredFlag() async {
      await emails.setFlag('jmap-1:old', flagged: true);
      now = now.add(const Duration(days: 8));
      await writer.expireParked('jmap-1', folder: 'mbox-in', role: 'inbox');
      return (await ops()).single;
    }

    test(
        'Retry of its expired change, once the copy is matched, sends it '
        'rewritten for the copy', () async {
      final failed = await expiredFlag();
      await storeServerCopyAndMatch();

      await emails.retryMutation(failed.id);

      final op = (await ops()).single;
      expect(op.state, 'pending');
      final payload = jsonDecode(op.payload) as Map;
      expect(payload['jmapId'], 'e7');
      expect(payload.containsKey('parkedShownIn'), isFalse);
      expect((await row('jmap-1:old'))!.isFlagged, isTrue);
      await expectConsistent();
    });

    test(
        'Retry of its expired change waits again without a copy, and stays '
        'failed once the row is gone', () async {
      final failed = await expiredFlag();

      await emails.retryMutation(failed.id);
      final again = (await ops()).single;
      expect(again.state, 'parked');

      await (db.update(db.pendingChanges)..where((t) => t.id.equals(again.id)))
          .write(const PendingChangesCompanion(state: Value('failed')));
      await writer.deleteRow('jmap-1:old');
      await emails.retryMutation(again.id);
      expect((await ops()).single.state, 'failed');
    });
  });

  group('an acked move whose new location is unknown', () {
    late int ackSeq;

    setUp(() async {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:a',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
              messageId: const Value('<a@test>'),
              srvUid: const Value(5),
            ),
          );
      await emails.moveEmail('acc-1:a', 'Archive');
      final op = (await ops()).single;
      // Sent, but neither COPYUID nor a search named the new UID.
      await (db.update(db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      await writer.ack(
        await (db.select(db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .getSingle(),
      );
      ackSeq = (await ops()).single.ackSeq!;
      // The source's enumeration no longer lists it.
      final read = await writer.beginRead('acc-1');
      expect(read.seq, greaterThan(ackSeq));
      await read.markGone(['acc-1:a']);
    });

    test('keeps showing the mail in its destination', () async {
      final op = (await ops()).single;
      expect(op.state, 'acked');
      expect(op.leaseUntil, isNotNull, reason: 'waits for the destination');
      final e = (await row('acc-1:a'))!;
      expect(e.srvGone, isTrue);
      expect(e.mailboxPath, 'Archive');
      expect(await writer.cleanUpGone('acc-1'), isEmpty);
      await expectConsistent();
    });

    test("the destination's copy fills it in place", () async {
      final read = await writer.beginRead('acc-1');
      await db.into(db.emails).insert(
            EmailStateWriter.newRow(
              EmailsCompanion.insert(
                id: 'unused',
                accountId: 'acc-1',
                mailboxPath: 'Archive',
                uid: 9,
                receivedAt: DateTime(2024),
                messageId: const Value('<a@test>'),
                srvUid: const Value(9),
              ),
              id: 'acc-1:copy',
              accountId: 'acc-1',
              mailboxPath: 'Archive',
              keywords: const ServerKeywords(
                seen: false,
                flagged: false,
                snoozedUntil: null,
              ),
              seq: read.seq,
            ),
          );

      await emails.matchArrivalForTest(
        'acc-1',
        'Archive',
        'acc-1:copy',
        '<a@test>',
      );

      expect(await row('acc-1:copy'), isNull);
      final e = (await row('acc-1:a'))!;
      expect(e.srvGone, isFalse);
      expect(e.srvMailboxPath, 'Archive');
      expect(e.srvUid, 9);
      expect(e.mailboxPath, 'Archive');
      expect(await ops(), isEmpty, reason: 'the move is confirmed');
      await expectConsistent();
    });

    test('resolves as satisfied when nothing appears in time', () async {
      now = now.add(EmailStateWriter.awaitAppearWindow);
      await writer.expireAwaitedMoves('acc-1');
      await writer.cleanUpGone('acc-1');

      expect(await ops(), isEmpty);
      expect(await row('acc-1:a'), isNull, reason: 'hidden, then cleaned up');
    });
  });
}
