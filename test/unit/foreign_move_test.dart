// When another client moves a mail, sync sees it vanish from one folder and
// appear in another with the same move-stable server id (RFC 8474 EMAILID).
// The row carries over with its id (SYNC-REDESIGN.md §6, phase 2c): the row
// sync stored at the new place is merged into it, never the other way round.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  setUp(() async {
    logs = await openRigWithMailA(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Spam': 33},
      folders: [('INBOX', 'inbox'), ('Archive', 'archive'), ('Spam', 'junk')],
      objectIds: true,
    );
  });
  tearDown(() => db.close());

  /// Another client moves a@test to Archive; sync sees Archive first (it
  /// stores a second row there), then INBOX (the mail vanished). Returns
  /// the id of the row stored in Archive.
  Future<String> moveElsewhereAndSync() async {
    server.moveElsewhere('a@test', 'Archive');
    await emails.syncEmails(_account.id, 'Archive');
    final copyId =
        (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Archive').id;
    return copyId;
  }

  Future<void> syncInbox() => emails.syncEmails(_account.id, 'INBOX');

  Future<void> addBody(String emailId, String text) =>
      db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(text),
            ),
          );

  Future<String?> bodyOf(String emailId) async => (await (db.select(
        db.emailBodies,
      )..where((t) => t.emailId.equals(emailId)))
              .getSingleOrNull())
          ?.textBody;

  test('a mail another client moved keeps its row, id and references',
      () async {
    final row = await rowOfA();
    final id = row.id;
    expect(row.serverEmailId, 'E-a@test');
    await addBody(id, 'cached body');
    await db.into(db.undoActions).insert(
          UndoActionsCompanion.insert(
            id: 'undo-1',
            accountId: _account.id,
            createdAt: now,
            dataJson: jsonEncode({
              'emailIds': [id],
            }),
          ),
        );
    await db.into(db.appLogs).insert(
          AppLogsCompanion.insert(
            createdAt: now,
            level: 'info',
            event: 'email.open',
            message: 'opened',
            emailId: Value(id),
          ),
        );
    await db.into(db.notifiedEmails).insert(
          NotifiedEmailsCompanion.insert(
            accountId: _account.id,
            emailId: id,
            notifiedAt: now,
          ),
        );

    final copyId = await moveElsewhereAndSync();
    expect(copyId, isNot(id));
    await syncInbox();

    final e = await rowOfA();
    expect(e.id, id);
    expect(e.mailboxPath, 'Archive');
    expect((e.srvMailboxPath, e.srvUid, e.srvUidValidity), ('Archive', 2, 22));
    expect(e.uid, 2);
    expect(await bodyOf(id), 'cached body');
    final undo = await (db.select(db.undoActions)
          ..where((t) => t.id.equals('undo-1')))
        .getSingle();
    expect(undo.dataJson, contains(id));
    final openLog = await (db.select(db.appLogs)
          ..where((t) => t.event.equals('email.open')))
        .getSingle();
    expect(openLog.emailId, id);
    final notified = await db.select(db.notifiedEmails).get();
    expect(notified.map((n) => n.emailId), [id]);
    // The thread lists follow: Archive shows the row, INBOX nothing.
    final threads = await db.select(db.threads).get();
    expect(threads.where((t) => t.mailboxPath == 'INBOX'), isEmpty);
    expect(
      threads.where((t) => t.mailboxPath == 'Archive' && t.latestEmailId == id),
      hasLength(1),
    );
    expect(
      threads.any((t) => t.emailIdsJson.contains(copyId)),
      isFalse,
    );

    final merged = logs.rows.singleWhere(
      (l) => l.event == 'email.duplicate_merged',
    );
    expect(merged.level, AppLogLevel.warn);
    expect(merged.emailId, id);
    expect(merged.mailboxPath, 'Archive');
    expect(
      jsonDecode(merged.dataJson!),
      containsPair('droppedEmailId', copyId),
    );
  });

  test('a change queued before the foreign move follows the mail', () async {
    final id = (await rowOfA()).id;
    await emails.setFlag(id, seen: true);

    await moveElsewhereAndSync();
    await syncInbox();

    final e = await rowOfA();
    expect(e.id, id);
    // The server's copy is still unread, but the queued change is the
    // user's: the row keeps showing it.
    expect(e.isSeen, isTrue);
    final change = await db.select(db.pendingChanges).getSingle();
    expect(change.resourceId, id);
    final payload = jsonDecode(change.payload) as Map<String, dynamic>;
    expect(
      (payload['mailboxPath'], payload['uid'], payload['uidValidity']),
      ('Archive', 2, 22),
    );

    await emails.flushPendingChanges(_account.id, 'pw');

    expect(server.find('a@test')!.message.seen, isTrue);
    expect(await unsettledChanges(db), isEmpty);
  });

  test("the copy's body and references move to the kept row", () async {
    final id = (await rowOfA()).id;
    final copyId = await moveElsewhereAndSync();
    // The user read and flagged the copy and started a reply to it before
    // INBOX was synced.
    await addBody(copyId, 'copy body');
    await emails.setFlag(copyId, flagged: true);
    await db.into(db.notifiedEmails).insert(
          NotifiedEmailsCompanion.insert(
            accountId: _account.id,
            emailId: copyId,
            notifiedAt: now,
          ),
        );
    await db.into(db.drafts).insert(
          DraftsCompanion.insert(
            accountId: Value(_account.id),
            replyToEmailId: Value(copyId),
            updatedAt: now,
          ),
        );

    await syncInbox();

    final e = await rowOfA();
    expect(e.id, id);
    expect(e.isFlagged, isTrue);
    expect(await bodyOf(id), 'copy body');
    expect(await bodyOf(copyId), isNull);
    final change = await db.select(db.pendingChanges).getSingle();
    expect((change.resourceId, change.changeType), (id, 'flag_flagged'));
    expect(
      (await db.select(db.notifiedEmails).get()).map((n) => n.emailId),
      [id],
    );
    expect((await db.select(db.drafts).getSingle()).replyToEmailId, id);
  });

  test('the kept row keeps its own body when both have one', () async {
    final id = (await rowOfA()).id;
    await addBody(id, 'own body');
    final copyId = await moveElsewhereAndSync();
    await addBody(copyId, 'copy body');

    await syncInbox();

    expect((await rowOfA()).id, id);
    expect(await bodyOf(id), 'own body');
    expect(await db.select(db.emailBodies).get(), hasLength(1));
  });

  test('no carry-over when more than one other row has the server id',
      () async {
    final id = (await rowOfA()).id;
    // A second row with that server id elsewhere (e.g. a stale one): which
    // of the two is the moved mail is unknown.
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc-1:other',
            accountId: _account.id,
            mailboxPath: 'Spam',
            uid: 9,
            receivedAt: DateTime(2024),
            messageId: const Value('a@test'),
            serverEmailId: const Value('E-a@test'),
            srvMailboxPath: const Value('Spam'),
            srvUid: const Value(9),
          ),
        );
    final copyId = await moveElsewhereAndSync();

    await syncInbox();

    final ids = (await rowsOfA()).map((e) => e.id).toSet();
    expect(ids, {copyId, 'acc-1:other'});
    expect(ids, isNot(contains(id)));
    expect(
      logs.rows.where((l) => l.event == 'email.duplicate_merged'),
      isEmpty,
    );
  });

  test('a mail expunged elsewhere is removed, not carried over', () async {
    server.expungeElsewhere('a@test');

    await syncInbox();

    expect(await rowsOfA(), isEmpty);
    expect(
      logs.rows.where((l) => l.event == 'email.duplicate_merged'),
      isEmpty,
    );
  });

  bool noMerge() => logs.rows.every((l) => l.event != 'email.duplicate_merged');

  Future<void> setCopyChangeState(String copyId, String state) =>
      (db.update(db.pendingChanges)..where((t) => t.resourceId.equals(copyId)))
          .write(
        PendingChangesCompanion(
          state: Value(state),
          leaseUntil: Value(now.add(const Duration(minutes: 5))),
        ),
      );

  test('a copy stored before a UIDVALIDITY change is not carried over',
      () async {
    final id = (await rowOfA()).id;
    final copyId = await moveElsewhereAndSync();
    // The copy's UID is from an earlier epoch of Archive: it may name
    // another mail now.
    await (db.update(db.emails)..where((t) => t.id.equals(copyId)))
        .write(const EmailsCompanion(srvUidValidity: Value(21)));

    await syncInbox();

    expect((await rowsOfA()).map((e) => e.id), [copyId]);
    expect((await rowsOfA()).map((e) => e.id), isNot(contains(id)));
    expect(noMerge(), isTrue);
  });

  test('a row whose own move left it with a stale UID carries over in place',
      () async {
    final id = (await rowOfA()).id;
    // Our move reached the server, but its answer was never recorded: the
    // row records Archive with the UID it had in INBOX (7 here, so it names
    // no mail in Archive).
    server.moveElsewhere('a@test', 'Archive');
    await (db.update(db.emails)..where((t) => t.id.equals(id))).write(
      const EmailsCompanion(
        mailboxPath: Value('Archive'),
        uid: Value(7),
        srvMailboxPath: Value('Archive'),
        srvUid: Value(7),
      ),
    );

    // Sync stores the mail in Archive a second time, and sees the stale
    // UID vanish.
    await emails.syncEmails(_account.id, 'Archive');

    final e = await rowOfA();
    expect(e.id, id);
    expect((e.mailboxPath, e.uid), ('Archive', 2));
    expect((e.srvMailboxPath, e.srvUid, e.srvUidValidity), ('Archive', 2, 22));
    expect(noMerge(), isFalse);
  });

  group('Gmail labels (one EMAILID in several folders)', () {
    test('a label removed: the row takes the only other label copy', () async {
      final id = (await rowOfA()).id;
      server.deliver('Spam', 'a@test');
      await emails.syncEmails(_account.id, 'Spam');
      expect(await rowsOfA(), hasLength(2));
      server.expungeElsewhere('a@test'); // the INBOX copy

      await syncInbox();

      final e = await rowOfA();
      expect((e.id, e.mailboxPath), (id, 'Spam'));
    });

    test('with two other label copies the row is removed', () async {
      final id = (await rowOfA()).id;
      server
        ..deliver('Spam', 'a@test')
        ..deliver('Archive', 'a@test');
      await emails.syncEmails(_account.id, 'Spam');
      await emails.syncEmails(_account.id, 'Archive');
      server.expungeElsewhere('a@test'); // the INBOX copy

      await syncInbox();

      final rows = await rowsOfA();
      expect(rows.map((e) => e.mailboxPath).toSet(), {'Spam', 'Archive'});
      expect(rows.map((e) => e.id), isNot(contains(id)));
      expect(noMerge(), isTrue);
    });
  });

  test("the copy's queued move carries over and is sent", () async {
    final id = (await rowOfA()).id;
    final copyId = await moveElsewhereAndSync();
    await emails.moveEmail(copyId, 'Spam');

    await syncInbox();

    var e = await rowOfA();
    expect(e.id, id);
    expect(e.mailboxPath, 'Spam');
    expect((e.srvMailboxPath, e.srvUid), ('Archive', 2));
    final move = await db.select(db.pendingChanges).getSingle();
    expect((move.resourceId, move.changeType), (id, 'move'));

    await emails.flushPendingChanges(_account.id, 'pw');

    expect(server.find('a@test')!.folder.path, 'Spam');
    e = await rowOfA();
    expect((e.id, e.mailboxPath, e.srvMailboxPath), (id, 'Spam', 'Spam'));
  });

  test('no merge while a change of the copy is being sent', () async {
    final id = (await rowOfA()).id;
    final copyId = await moveElsewhereAndSync();
    await emails.setFlag(copyId, flagged: true);
    await setCopyChangeState(copyId, 'inflight');

    await syncInbox();

    // Both rows are kept; the next sync carries the row over.
    expect((await rowsOfA()).map((e) => e.id).toSet(), {id, copyId});
    expect(noMerge(), isTrue);

    await setCopyChangeState(copyId, 'pending');
    await syncInbox();

    expect((await rowOfA()).id, id);
  });

  test('a row with a queued move of its own is left alone', () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Spam');
    final copyId = await moveElsewhereAndSync();

    await syncInbox();

    expect((await rowsOfA()).map((e) => e.id).toSet(), {id, copyId});
    expect(noMerge(), isTrue);
  });

  test('a row of another account with the server id is no match', () async {
    await AccountRepositoryImpl(db, FakeSecureStorage()).addAccount(
      const Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      ),
      'pw',
    );
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc-2:x',
            accountId: 'acc-2',
            mailboxPath: 'Archive',
            uid: 2,
            receivedAt: DateTime(2024),
            messageId: const Value('a@test'),
            serverEmailId: const Value('E-a@test'),
            srvMailboxPath: const Value('Archive'),
            srvUid: const Value(2),
          ),
        );
    server.expungeElsewhere('a@test');

    await syncInbox();

    expect((await rowsOfA()).map((e) => e.id), ['acc-2:x']);
    expect(noMerge(), isTrue);
  });

  test('a local virtual row with the server id does not count', () async {
    final id = (await rowOfA()).id;
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc-1:local',
            accountId: _account.id,
            mailboxPath: 'Sent',
            uid: 0,
            receivedAt: DateTime(2024),
            messageId: const Value('local@test'),
            serverEmailId: const Value('E-a@test'),
            isLocal: const Value(true),
          ),
        );
    await moveElsewhereAndSync();

    await syncInbox();

    expect((await rowOfA()).id, id);
    final local = await (db.select(db.emails)
          ..where((t) => t.id.equals('acc-1:local')))
        .getSingleOrNull();
    expect(local, isNotNull);
  });

  test('both rows changed the same flag: the newer change shows', () async {
    final id = (await rowOfA()).id;
    await emails.setFlag(id, seen: true);
    server.moveElsewhere('a@test', 'Archive');
    server.setFlagElsewhere('a@test', r'\Seen', on: true);
    await emails.syncEmails(_account.id, 'Archive');
    final copyId =
        (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Archive').id;
    await emails.setFlag(copyId, seen: false);

    await syncInbox();

    final e = await rowOfA();
    expect((e.id, e.isSeen), (id, false));
    final changes = await db.select(db.pendingChanges).get();
    expect(changes.map((c) => c.resourceId).toSet(), {id});

    await emails.flushPendingChanges(_account.id, 'pw');

    expect(server.find('a@test')!.message.seen, isFalse);
  });

  group('downloaded attachments of the merged copy', () {
    String dirOf(String emailId) => p.join(
          rig.cacheDir.path,
          'sharedinbox',
          'attachments',
          emailId.replaceAll(':', '_'),
        );

    Future<void> download(String emailId) async {
      final file = File(p.join(dirOf(emailId), 'a.pdf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('pdf');
      await db.into(db.attachmentFiles).insert(
            AttachmentFilesCompanion.insert(
              emailId: emailId,
              filename: 'a.pdf',
              size: file.lengthSync(),
              downloadedAt: now,
            ),
          );
    }

    test('move to the kept row with the body', () async {
      final id = (await rowOfA()).id;
      final copyId = await moveElsewhereAndSync();
      await addBody(copyId, 'copy body');
      await download(copyId);

      await syncInbox();

      expect(File(p.join(dirOf(id), 'a.pdf')).existsSync(), isTrue);
      expect(Directory(dirOf(copyId)).existsSync(), isFalse);
      final files = await db.select(db.attachmentFiles).get();
      expect(files.map((f) => f.emailId), [id]);
    });

    test('are deleted when the kept row has its own body', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'own body');
      final copyId = await moveElsewhereAndSync();
      await addBody(copyId, 'copy body');
      await download(copyId);

      await syncInbox();

      expect(Directory(dirOf(copyId)).existsSync(), isFalse);
      expect(Directory(dirOf(id)).existsSync(), isFalse);
      expect(await db.select(db.attachmentFiles).get(), isEmpty);
    });
  });
}
