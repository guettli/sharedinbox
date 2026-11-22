// Counterpart shadow ops (SYNC-REDESIGN.md §6, phase 4b): one server added
// twice, once via IMAP and once via JMAP. A user action on one account's row
// gives the twin row of the other account a shadow of the queued change: it
// shows there at once, is never sent (the server message changes once), and
// is acked, dropped or failed with its primary. Also the unread-count delta
// (§7), which counts the changes a stored server count does not reflect.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'helpers/offline_repos.dart';
import 'recording_app_log_repository.dart';

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
      'a move into a folder the counterpart does not know parks the twin '
      "on a stand-in folder there, parked on the folder's creation (5b)",
      () async {
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
    expect(twin.mailboxPath, startsWith('~new:'), reason: 'shown, not hidden');
    final standIn = await (db.select(db.mailboxes)
          ..where((t) => t.path.equals(twin.mailboxPath)))
        .getSingle();
    expect(
      (standIn.accountId, standIn.name, standIn.isLocal),
      (
        'jmap-p',
        'Projects',
        true,
      ),
    );
    final shadows = await opsOf('jmap-p');
    expect(
      shadows.map((o) => (o.changeType, o.state)),
      unorderedEquals([('create_mailbox', 'shadow'), ('move', 'shadow')]),
    );
    // Never sent: the counterpart's flush has nothing to do.
    expect(await emails.flushPendingChanges('jmap-p', 'pw'), 0);
    expect(jmapRequests, isEmpty);
    await expectConsistent();
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);

    // Undo: the twin shows again, with its body and id; the stand-in goes.
    await emails.cancelOps(captured['imap-p:5']!);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-in');
    expect(await opsOf('jmap-p'), isEmpty);
    await MailboxStateWriter(db).dropOrphanedCounterpartFolders('jmap-p');
    expect(
      (await db.select(db.mailboxes).get()).map((m) => m.id),
      isNot(contains(standIn.id)),
    );
    await expectConsistent();
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
  });

  test(
      'a stand-in two moves need stays while either is live: Undo of the '
      'first keeps the folder the second twin shows in', () async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'imap-p:Projects',
            accountId: 'imap-p',
            path: 'Projects',
            name: 'Projects',
          ),
        );
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'imap-p:6',
            accountId: 'imap-p',
            mailboxPath: 'INBOX',
            uid: 6,
            receivedAt: DateTime(2024),
            messageId: const Value('<def@example.com>'),
            srvUid: const Value(6),
          ),
        );
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'jmap-p:e2',
            accountId: 'jmap-p',
            mailboxPath: 'mbox-in',
            uid: 0,
            receivedAt: DateTime(2024),
            messageId: const Value('def@example.com'),
            srvJmapId: const Value('e2'),
          ),
        );
    final (_, first) = await emails.captureOps(
      () => emails.moveEmail('imap-p:5', 'Projects'),
    );
    await emails.moveEmail('imap-p:6', 'Projects');
    final standIn = (await row('jmap-p:e1')).mailboxPath;
    expect((await row('jmap-p:e2')).mailboxPath, standIn);

    await emails.cancelOps(first['imap-p:5']!);
    await MailboxStateWriter(db).dropOrphanedCounterpartFolders('jmap-p');

    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-in');
    expect((await row('jmap-p:e2')).mailboxPath, standIn);
    expect(
      (await db.select(db.mailboxes).get()).map((m) => m.path),
      contains(standIn),
    );
    await expectConsistent();
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
  });

  test(
      "the counterpart's listing adopts the stand-in folder; a read of the "
      'mail there settles the shadow', () async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'imap-p:Projects',
            accountId: 'imap-p',
            path: 'Projects',
            name: 'Projects',
          ),
        );
    await emails.moveEmail('imap-p:5', 'Projects');
    final standInPath = (await row('jmap-p:e1')).mailboxPath;
    final primary = (await opsOf('imap-p')).single;
    await (db.update(db.pendingChanges)..where((t) => t.id.equals(primary.id)))
        .write(const PendingChangesCompanion(state: Value('inflight')));
    final writer = EmailStateWriter(db);
    await writer.ack(
      await (db.select(db.pendingChanges)
            ..where((t) => t.id.equals(primary.id)))
          .getSingle(),
    );

    // The counterpart lists the folder the primary moved the mail into.
    await MailboxStateWriter(db).writeServer(
      accountId: 'jmap-p',
      path: 'mbox-projects',
      name: 'Projects',
      role: null,
      parentId: null,
      unreadCount: 0,
      totalCount: 1,
      unreadSeq: 0,
      readSeq: await writer.nextReadSeq(),
    );
    final adopted = await (db.select(db.mailboxes)
          ..where((t) => t.path.equals('mbox-projects')))
        .getSingle();
    expect(adopted.isLocal, isFalse);
    expect(
      (await db.select(db.mailboxes).get()).map((m) => m.path),
      isNot(contains(standInPath)),
    );
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-projects');

    // A read of the counterpart finds the mail there.
    final read = await writer.beginRead('jmap-p');
    await read.writeLocation('jmap-p:e1', 'mbox-projects');

    expect(await opsOf('jmap-p'), isEmpty);
    expect((await row('jmap-p:e1')).mailboxPath, 'mbox-projects');
    await expectConsistent();
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
  });

  group('a stand-in for a nested folder (6b)', () {
    Future<void> folder(
      String account,
      String path,
      String name, {
      String? parentId,
    }) =>
        db.into(db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: '$account:$path',
                accountId: account,
                path: path,
                name: name,
                parentId: Value(parentId),
              ),
            );
    Future<MailboxRow> mailbox(String path) =>
        (db.select(db.mailboxes)..where((t) => t.path.equals(path)))
            .getSingle();
    Future<PendingChangeRow> shadowCreate(String accountId) async =>
        (await opsOf(accountId))
            .singleWhere((o) => o.changeType == 'create_mailbox');
    Future<void> ackPrimary(String accountId) async {
      final primary = (await opsOf(accountId)).single;
      await (db.update(db.pendingChanges)
            ..where((t) => t.id.equals(primary.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      await EmailStateWriter(db).ack(
        await (db.select(db.pendingChanges)
              ..where((t) => t.id.equals(primary.id)))
            .getSingle(),
      );
    }

    /// The primary is acked, then the counterpart's listing has the folder
    /// at [path] (below [parentId] on JMAP): [standIn] becomes it, keeping
    /// its id, its shadow create goes, and twin [twinId] shows there.
    Future<void> listingAdopts(
      MailboxRow standIn, {
      required String primaryAccount,
      required String path,
      required String twinId,
      String? parentId,
    }) async {
      await ackPrimary(primaryAccount);
      await MailboxStateWriter(db).writeServer(
        accountId: standIn.accountId,
        path: path,
        name: standIn.name,
        role: null,
        parentId: parentId,
        unreadCount: 0,
        totalCount: 1,
        unreadSeq: 0,
        readSeq: await EmailStateWriter(db).nextReadSeq(),
      );

      final adopted = await mailbox(path);
      expect((adopted.id, adopted.isLocal), (standIn.id, false));
      expect((await row(twinId)).mailboxPath, path);
      expect(
        (await opsOf(standIn.accountId)).map((o) => o.changeType),
        isNot(contains('create_mailbox')),
      );
      await expectConsistent();
      expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
    }

    test(
        'JMAP: made below the parent the counterpart has (not a same-named '
        'folder elsewhere), never sent, no stand-in id as a parent; the '
        "listing adopts it when the server's folder is nested", () async {
      await folder('imap-p', 'Projects', 'Projects');
      await folder('imap-p', 'Projects/2026', '2026');
      await folder('jmap-p', 'mbox-proj', 'Projects');
      // A "2026" below another folder is not the destination.
      await folder('jmap-p', 'mbox-other', 'Other');
      await folder('jmap-p', 'mbox-o2026', '2026', parentId: 'mbox-other');

      await emails.moveEmail('imap-p:5', 'Projects/2026');

      final twin = await row('jmap-p:e1');
      expect(twin.mailboxPath, startsWith('~new:'));
      final standIn = await mailbox(twin.mailboxPath);
      expect(
        (standIn.isLocal, standIn.name, standIn.parentId, standIn.displayPath),
        (true, '2026', 'mbox-proj', 'Projects/2026'),
      );
      final create = await shadowCreate('jmap-p');
      expect(create.state, 'shadow');
      expect(
        (jsonDecode(create.payload) as Map<String, dynamic>)['parent'],
        'mbox-proj',
      );
      expect(await emails.flushPendingChanges('jmap-p', 'pw'), 0);
      expect(jmapRequests, isEmpty, reason: 'its create is never sent');
      await expectConsistent();
      expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);

      await listingAdopts(
        standIn,
        primaryAccount: 'imap-p',
        path: 'mbox-2026',
        parentId: 'mbox-proj',
        twinId: 'jmap-p:e1',
      );
    });

    test(
        'JMAP: a parent the counterpart does not know puts the stand-in at '
        'the top level, never into a same-named folder elsewhere', () async {
      await folder('imap-p', 'Projects', 'Projects');
      await folder('imap-p', 'Projects/2026', '2026');
      // A decoy: "Other/2026" is not "Projects/2026".
      await folder('jmap-p', 'mbox-other', 'Other');
      await folder('jmap-p', 'mbox-o2026', '2026', parentId: 'mbox-other');

      await emails.moveEmail('imap-p:5', 'Projects/2026');

      final twinPath = (await row('jmap-p:e1')).mailboxPath;
      expect(twinPath, isNot('mbox-o2026'));
      final standIn = await mailbox(twinPath);
      expect(standIn.isLocal, isTrue);
      expect(standIn.parentId, isNull);
      expect(
        (jsonDecode((await shadowCreate('jmap-p')).payload)
                as Map<String, dynamic>)
            .containsKey('parent'),
        isFalse,
      );
      await expectConsistent();
    });

    test(
        'IMAP: a stand-in at the top level (parent unknown) is adopted by '
        'its name when the listing has the folder nested', () async {
      await folder('jmap-p', 'mbox-proj', 'Projects');
      await folder('jmap-p', 'mbox-2026', '2026', parentId: 'mbox-proj');

      await emails.moveEmail('jmap-p:e1', 'mbox-2026');

      final standIn = await mailbox('2026');
      expect((standIn.isLocal, standIn.accountId), (true, 'imap-p'));
      await listingAdopts(
        standIn,
        primaryAccount: 'jmap-p',
        path: 'Projects/2026',
        twinId: 'imap-p:5',
      );
    });

    test(
        "a parent level is matched by name before by role: the user's own "
        '"Trash" is not taken for the counterpart\'s "Deleted Items"',
        () async {
      await folder('imap-p', 'Trash', 'Trash');
      await db.customUpdate(
        "UPDATE mailboxes SET role = 'trash' WHERE id = 'imap-p:Trash'",
      );
      await folder('imap-p', 'Trash/Old', 'Old');
      await folder('jmap-p', 'mbox-deleted', 'Deleted Items');
      await db.customUpdate(
        "UPDATE mailboxes SET role = 'trash' WHERE id = 'jmap-p:mbox-deleted'",
      );
      await folder('jmap-p', 'mbox-trash', 'Trash');

      await emails.moveEmail('imap-p:5', 'Trash/Old');

      final standIn = await mailbox((await row('jmap-p:e1')).mailboxPath);
      expect(standIn.parentId, 'mbox-trash');
    });

    test(
        'IMAP: made at the path the server gives the nested folder, and the '
        'listing of that path takes it over', () async {
      await folder('jmap-p', 'mbox-proj', 'Projects');
      await folder('jmap-p', 'mbox-2026', '2026', parentId: 'mbox-proj');
      await folder('imap-p', 'Projects', 'Projects');

      await emails.moveEmail('jmap-p:e1', 'mbox-2026');

      final twin = await row('imap-p:5');
      expect(twin.mailboxPath, 'Projects/2026');
      final standIn = await mailbox('Projects/2026');
      expect(
        (standIn.isLocal, standIn.accountId, standIn.displayPath),
        (true, 'imap-p', 'Projects/2026'),
      );
      expect(
        (jsonDecode((await shadowCreate('imap-p')).payload)
            as Map<String, dynamic>)['parent'],
        'Projects',
      );
      await expectConsistent();
      expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);

      await listingAdopts(
        standIn,
        primaryAccount: 'jmap-p',
        path: 'Projects/2026',
        twinId: 'imap-p:5',
      );
    });
  });

  group('an IMAP twin shown in a folder through a shadow', () {
    setUp(() async {
      // The user archives on the JMAP account: the IMAP twin shows Archive,
      // while its server location is still INBOX, UID 5.
      await emails.moveEmail('jmap-p:e1', 'mbox-arch');
      expect((await row('imap-p:5')).mailboxPath, 'Archive');
      expect((await row('imap-p:5')).srvMailboxPath, 'INBOX');
    });

    Future<Map<String, dynamic>> lastPayloadOf(String accountId) async =>
        jsonDecode((await opsOf(accountId)).last.payload)
            as Map<String, dynamic>;

    test(
        'a star queued on it finds the mail by Message-ID, not by the UID '
        'of INBOX', () async {
      await emails.setFlag('imap-p:5', flagged: true);

      final payload = await lastPayloadOf('imap-p');
      expect(payload['mailboxPath'], 'Archive');
      expect(payload['uidAfterMove'], isTrue);
      expect(payload['messageId'], '<abc@example.com>');
    });

    test('so does a move out of it', () async {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'imap-p:Projects',
              accountId: 'imap-p',
              path: 'Projects',
              name: 'Projects',
            ),
          );
      await emails.moveEmail('imap-p:5', 'Projects');

      final payload = await lastPayloadOf('imap-p');
      expect(payload['mailboxPath'], 'Archive');
      expect(payload['uidAfterMove'], isTrue);
    });

    test(
        'once acked, it waits for the IMAP Archive copy instead of hiding '
        'the twin when INBOX no longer lists it', () async {
      final primary = (await opsOf('jmap-p')).single;
      await (db.update(db.pendingChanges)
            ..where((t) => t.id.equals(primary.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      final writer = EmailStateWriter(db);
      await writer.ack(
        await (db.select(db.pendingChanges)
              ..where((t) => t.id.equals(primary.id)))
            .getSingle(),
      );

      final read = await writer.beginRead('imap-p');
      await read.markGone(['imap-p:5']);

      final shadow = (await opsOf('imap-p')).single;
      expect(shadow.state, 'acked');
      expect(shadow.leaseUntil, isNotNull);
      expect((await row('imap-p:5')).mailboxPath, 'Archive');
      await expectConsistent();
    });
  });

  group('unread-count delta', () {
    late MailboxRepositoryImpl mailboxes;
    late RecordingAppLogRepository logs;

    setUp(() async {
      logs = RecordingAppLogRepository();
      mailboxes =
          MailboxRepositoryImpl(db, accounts, appLogger: AppLogger(logs));
      // The server counted 3 unread of 3 in INBOX (one of them is
      // imap-p:5), and an empty Archive.
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(
        const MailboxesCompanion(
          unreadCount: Value(3),
          totalCount: Value(3),
          unreadSeq: Value(0),
        ),
      );
      await (db.update(db.mailboxes)
            ..where((t) => t.id.equals('imap-p:Archive')))
          .write(
        const MailboxesCompanion(unreadCount: Value(0), totalCount: Value(0)),
      );
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

    Future<Map<String, (int, int)>> counts() async => {
          for (final m in await mailboxes.observeMailboxes('imap-p').first)
            m.path: (m.unreadCount, m.totalCount),
        };

    /// Acks the queued change [op] as a flush would.
    Future<void> ackOp(PendingChangeRow op) async {
      await (db.update(db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      await EmailStateWriter(db).ack(
        await (db.select(db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .getSingle(),
      );
    }

    test('a queued move of an unread mail moves its count', () async {
      await emails.moveEmail('imap-p:5', 'Archive');
      expect(await unread(), {'Archive': 1, 'INBOX': 2});
    });

    test(
        'a queued move of an unread mail moves its total too: the target '
        'never shows unread mail in a folder counted empty (#1333)', () async {
      await emails.moveEmail('imap-p:5', 'Archive');
      expect(await counts(), {'Archive': (1, 1), 'INBOX': (2, 2)});

      await emails.deleteEmail('imap-p:5');
      final shown = await counts();
      expect(shown['Archive'], (0, 0));
      expect(shown['INBOX'], (2, 2));
    });

    test(
        'marked read, then moved: the read reached the server before the '
        'count, the move not yet; not taken off the count twice (#1333)',
        () async {
      // The server counted imap-p:5 as the only unread mail of INBOX.
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(const MailboxesCompanion(unreadCount: Value(1)));
      await emails.setFlag('imap-p:5', seen: true);
      await emails.moveEmail('imap-p:5', 'Archive');
      expect(await unread(), {'Archive': 0, 'INBOX': 0});

      // Back online: the read change is sent and acked, then a sync counts
      // INBOX again (no unread left there); the move is still queued.
      final flag = (await opsOf('imap-p'))
          .singleWhere((o) => o.changeType == 'flag_seen');
      await ackOp(flag);
      final seq = await EmailStateWriter(db).nextReadSeq();
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(
        MailboxesCompanion(unreadCount: const Value(0), unreadSeq: Value(seq)),
      );

      expect(await unread(), {'Archive': 0, 'INBOX': 0});
      await pumpEventQueue();
      expect(
        logs.rows.map((r) => r.event),
        isNot(contains('mailbox.unread_negative')),
      );
      expect(await counts(), {'Archive': (0, 1), 'INBOX': (0, 2)});

      // The move is acked too and the folders are counted after it.
      final move =
          (await opsOf('imap-p')).singleWhere((o) => o.changeType == 'move');
      await ackOp(move);
      final after = await EmailStateWriter(db).nextReadSeq();
      for (final (id, total) in const [
        ('imap-p:INBOX', 2),
        ('imap-p:Archive', 1),
      ]) {
        await (db.update(db.mailboxes)..where((t) => t.id.equals(id))).write(
          MailboxesCompanion(
            unreadCount: const Value(0),
            totalCount: Value(total),
            unreadSeq: Value(after),
          ),
        );
      }
      expect(await counts(), {'Archive': (0, 1), 'INBOX': (0, 2)});
      await pumpEventQueue();
      expect(
        logs.rows.map((r) => r.event),
        isNot(contains('mailbox.unread_negative')),
      );
    });

    test('a real inconsistency is still logged, once', () async {
      // The count is older than the mail: the server never counted it.
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(const MailboxesCompanion(unreadCount: Value(0)));
      await emails.moveEmail('imap-p:5', 'Archive');
      expect((await counts())['INBOX'], (0, 2));
      expect((await counts())['INBOX'], (0, 2));
      await pumpEventQueue();
      expect(
        logs.rows.where((r) => r.event == 'mailbox.unread_negative'),
        hasLength(1),
      );
    });

    test('a count read before a mail arrived does not go below 0', () async {
      // The stored count (3) is older than the mails: none is unread on the
      // server as last read, so a queued move of an unread row would make
      // INBOX -1 below a count that never had it.
      await (db.update(db.mailboxes)..where((t) => t.id.equals('imap-p:INBOX')))
          .write(const MailboxesCompanion(unreadCount: Value(0)));
      await emails.moveEmail('imap-p:5', 'Archive');
      expect(await unread(), {'Archive': 1, 'INBOX': 0});
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
