// Counterpart shadow ops (SYNC-REDESIGN.md §6, phase 4b): one server added
// twice, once via IMAP and once via JMAP. A user action on one account's row
// gives the twin row of the other account a shadow of the queued change: it
// shows there at once, is never sent (the server message changes once), and
// is acked, dropped or failed with its primary. Also the unread-count delta
// (§7), which counts the changes a stored server count does not reflect.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'helpers/offline_repos.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late AccountRepositoryImpl accounts;
  late EmailRepositoryImpl emails;
  late List<http.Request> jmapRequests;

  setUp(() async {
    db = openTestDatabase();
    accounts = AccountRepositoryImpl(db, MapSecureStorage());
    jmapRequests = [];
    emails = offlineEmailRepository(
      db,
      accounts,
      // A shadow is never sent: any JMAP request is a failure.
      httpClient: MockClient((request) async {
        jmapRequests.add(request);
        return http.Response('unexpected', 500);
      }),
    );
    await accounts.addAccount(aliceImap('imap-p'), 'pw');
    await accounts.addAccount(aliceJmap('jmap-p'), 'pw');
    for (final (account, path, name, role) in const [
      ('imap-p', 'INBOX', 'Inbox', 'inbox'),
      ('imap-p', 'Archive', 'Archive', 'archive'),
      ('jmap-p', 'mbox-in', 'Inbox', 'inbox'),
      ('jmap-p', 'mbox-arch', 'Archive', 'archive'),
    ]) {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: '$account:$path',
              accountId: account,
              path: path,
              name: name,
              role: Value(role),
            ),
          );
    }
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'imap-p:5',
            accountId: 'imap-p',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
            messageId: const Value('<abc@example.com>'),
            srvUid: const Value(5),
          ),
        );
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'jmap-p:e1',
            accountId: 'jmap-p',
            mailboxPath: 'mbox-in',
            uid: 0,
            receivedAt: DateTime(2024),
            messageId: const Value('abc@example.com'),
            srvJmapId: const Value('e1'),
          ),
        );
  });
  tearDown(() => db.close());

  Future<List<PendingChangeRow>> opsOf(String accountId) =>
      (db.select(db.pendingChanges)
            ..where((t) => t.accountId.equals(accountId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
  Future<Email> row(String id) =>
      (db.select(db.emails)..where((t) => t.id.equals(id))).getSingle();
  Future<void> expectConsistent() async =>
      expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);

  test('a move gives the twin a shadow: shown, never sent', () async {
    await emails.moveEmail('imap-p:5', 'Archive');

    final primary = (await opsOf('imap-p')).single;
    expect(primary.state, 'pending');
    final shadow = (await opsOf('jmap-p')).single;
    expect(shadow.state, 'shadow');
    expect(shadow.origin, 'counterpart:${primary.id}');
    expect(shadow.changeType, 'move');
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-arch');

    // The counterpart's flush has nothing to send.
    expect(await emails.flushPendingChanges('jmap-p', 'pw'), 0);
    expect(jmapRequests, isEmpty);
    // Not listed on the Pending Changes screen, not unsynced work.
    expect(await emails.observePendingChanges('jmap-p').first, isEmpty);
    await expectConsistent();
  });

  test('Undo cancelling the primary takes the shadow along', () async {
    final (_, captured) = await emails.captureOps(
      () => emails.moveEmail('imap-p:5', 'Archive'),
    );
    expect(captured.keys, ['imap-p:5'], reason: 'a shadow is not captured');

    await emails.cancelOps(captured['imap-p:5']!);

    expect(await opsOf('imap-p'), isEmpty);
    expect(await opsOf('jmap-p'), isEmpty);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-in');
    expect((await row('imap-p:5')).mailboxPath, 'INBOX');
    await expectConsistent();
  });

  test(
      'the ack of the primary acks the shadow with the same sequence; a '
      'read of the counterpart settles it', () async {
    await emails.moveEmail('imap-p:5', 'Archive');
    final primary = (await opsOf('imap-p')).single;
    await (db.update(db.pendingChanges)..where((t) => t.id.equals(primary.id)))
        .write(const PendingChangesCompanion(state: Value('inflight')));

    final writer = EmailStateWriter(db);
    await writer.ack(
      (await (db.select(db.pendingChanges)
            ..where((t) => t.id.equals(primary.id)))
          .getSingle()),
    );

    final acked = (await opsOf('imap-p')).single;
    final shadow = (await opsOf('jmap-p')).single;
    expect(shadow.state, 'acked');
    expect(shadow.ackSeq, acked.ackSeq);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-arch');

    // The counterpart's next read finds the mail in its Archive.
    final read = await writer.beginRead('jmap-p');
    await read.writeLocation('jmap-p:e1', 'mbox-arch');

    expect(await opsOf('jmap-p'), isEmpty);
    final twin = await row('jmap-p:e1');
    expect(twin.mailboxPath, 'mbox-arch');
    expect(twin.srvMailboxPath, 'mbox-arch');
    await expectConsistent();
  });

  test('a failed primary drops its shadow (no shadow folds forever)', () async {
    await emails.moveEmail('imap-p:5', 'Archive');
    final primary = (await opsOf('imap-p')).single;
    // Failed by a path that did not take the shadow along.
    await (db.update(db.pendingChanges)..where((t) => t.id.equals(primary.id)))
        .write(const PendingChangesCompanion(state: Value('failed')));
    await EmailStateWriter(db).refold('imap-p:5');

    final problems = await EmailStateWriter(db).consistencyProblems();
    expect(problems.single.emailId, 'jmap-p:e1');
    expect(problems.single.fields, ['shadow']);

    await EmailStateWriter(db).dropOrphanedShadows();

    expect(await opsOf('jmap-p'), isEmpty);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-in');
    await expectConsistent();
  });

  test('a delete gives the twin a shadow too', () async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'imap-p:Trash',
            accountId: 'imap-p',
            path: 'Trash',
            name: 'Trash',
            role: const Value('trash'),
          ),
        );
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'jmap-p:mbox-t',
            accountId: 'jmap-p',
            path: 'mbox-t',
            name: 'Trash',
            role: const Value('trash'),
          ),
        );

    await emails.deleteEmails(['imap-p:5']);

    final primary = (await opsOf('imap-p')).single;
    final shadow = (await opsOf('jmap-p')).single;
    expect(shadow.state, 'shadow');
    expect(shadow.origin, 'counterpart:${primary.id}');
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-t');
    await expectConsistent();
  });

  test(
      'a move into a folder the counterpart does not know hides the twin '
      'with a shadow instead of deleting it', () async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'imap-p:Projects',
            accountId: 'imap-p',
            path: 'Projects',
            name: 'Projects',
          ),
        );
    final (_, captured) = await emails.captureOps(
      () => emails.moveEmail('imap-p:5', 'Projects'),
    );

    final twin = await row('jmap-p:e1');
    expect(twin.mailboxPath, '', reason: 'hidden, not deleted');
    final shadow = (await opsOf('jmap-p')).single;
    expect(shadow.changeType, 'delete');
    expect(shadow.state, 'shadow');
    await expectConsistent();

    // Undo: the twin shows again, with its body and id.
    await emails.cancelOps(captured['imap-p:5']!);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-in');
    expect(await opsOf('jmap-p'), isEmpty);
    await expectConsistent();
  });

  test(
      'an acked hiding shadow settles when the counterpart reads the mail '
      'in its new folder', () async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'imap-p:Projects',
            accountId: 'imap-p',
            path: 'Projects',
            name: 'Projects',
          ),
        );
    await emails.moveEmail('imap-p:5', 'Projects');
    final primary = (await opsOf('imap-p')).single;
    await (db.update(db.pendingChanges)..where((t) => t.id.equals(primary.id)))
        .write(const PendingChangesCompanion(state: Value('inflight')));
    final writer = EmailStateWriter(db);
    await writer.ack(
      await (db.select(db.pendingChanges)
            ..where((t) => t.id.equals(primary.id)))
          .getSingle(),
    );

    // The counterpart learnt the new folder and finds the mail there.
    final read = await writer.beginRead('jmap-p');
    await read.writeLocation('jmap-p:e1', 'mbox-projects');

    expect(await opsOf('jmap-p'), isEmpty);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-projects');
    await expectConsistent();
  });

  group('unread-count delta', () {
    late MailboxRepositoryImpl mailboxes;

    setUp(() async {
      mailboxes = MailboxRepositoryImpl(db, accounts);
      // The server counted 3 unread in INBOX (one of them is imap-p:5).
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(
        const MailboxesCompanion(unreadCount: Value(3), unreadSeq: Value(0)),
      );
      await (db.update(db.mailboxes)
            ..where((t) => t.id.equals('imap-p:Archive')))
          .write(const MailboxesCompanion(unreadCount: Value(0)));
      await db.customStatement(
        'UPDATE emails SET is_seen = 0, srv_is_seen = 0 '
        "WHERE id = 'imap-p:5'",
      );
    });

    Future<Map<String, int>> unread() async => {
          for (final m in await mailboxes.observeMailboxes('imap-p').first)
            m.path: m.unreadCount,
        };

    test('a queued read change shows at once', () async {
      await emails.setFlag('imap-p:5', seen: true);
      expect(await unread(), {'Archive': 0, 'INBOX': 2});
    });

    test('a queued move of an unread mail moves its count', () async {
      await emails.moveEmail('imap-p:5', 'Archive');
      expect(await unread(), {'Archive': 1, 'INBOX': 2});
    });

    test('an acked change counts until a count read after the ack', () async {
      await emails.setFlag('imap-p:5', seen: true);
      final op = (await opsOf('imap-p')).single;
      await (db.update(db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      final writer = EmailStateWriter(db);
      await writer.ack(
        await (db.select(db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .getSingle(),
      );
      // The stored count was read before the ack: still adjusted.
      expect((await unread())['INBOX'], 2);

      // A count read after the ack already reflects it: not counted twice.
      final seq = await writer.nextReadSeq();
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(
        MailboxesCompanion(
          unreadCount: const Value(2),
          unreadSeq: Value(seq),
        ),
      );
      expect((await unread())['INBOX'], 2);
    });
  });
}
