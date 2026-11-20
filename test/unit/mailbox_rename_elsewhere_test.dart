// A folder another IMAP client renamed or moved is followed by its RFC 8474
// MAILBOXID when the server gives folder ids (#1315): an empty folder under
// a new UIDVALIDITY, a rename and a move at once, two candidates. Ids that
// differ are never matched by contents; without OBJECTID the UIDVALIDITY /
// Message-ID rules stay as they were.

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/imap/mailbox_id_status.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  group('parseStatusLine', () {
    test('reads the counts and the MAILBOXID', () {
      expect(
        parseStatusLine(
          'STATUS "Work" (MESSAGES 3 UNSEEN 1 UIDVALIDITY 77 '
          'MAILBOXID (eaaaaah))',
        ),
        (messages: 3, unseen: 1, uidValidity: 77, mailboxId: 'eaaaaah'),
      );
    });

    test('a folder name that looks like an item does not count', () {
      expect(
        parseStatusLine('STATUS "MESSAGES 9 (x)" (MAILBOXID (F1))'),
        (messages: 0, unseen: 0, uidValidity: null, mailboxId: 'F1'),
      );
    });

    test('no MAILBOXID, or no STATUS response', () {
      expect(
        parseStatusLine('STATUS INBOX (MESSAGES 2)')?.mailboxId,
        isNull,
      );
      expect(parseStatusLine('LIST () "/" "INBOX"'), isNull);
    });
  });

  late RecordingAppLogRepository logs;
  Future<void> open({required bool objectIds}) async {
    logs = await openRigWithMailA(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22},
      folders: [('INBOX', 'inbox'), ('Archive', 'archive')],
      objectIds: objectIds,
    );
  }

  Future<void> listFolders() => rig.mailboxes.syncMailboxes(_acc.id);
  Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
  Iterable<String> events() => logs.rows.map((r) => r.event);
  Future<MailboxRow> folderAt(String path) async =>
      (await db.select(db.mailboxes).get()).singleWhere((m) => m.path == path);
  Future<MailboxRow?> folderById(String id) =>
      MailboxStateWriter(db).rowById(id);
  Future<Email> mail(String messageId) =>
      (db.select(db.emails)..where((t) => t.messageId.equals(messageId)))
          .getSingle();
  Future<void> expectConsistent() async {
    expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
  }

  Future<void> workWith(List<String> messageIds) async {
    server.addFolder('Work');
    for (final id in messageIds) {
      server.deliver('Work', id);
    }
    await listFolders();
    if (messageIds.isNotEmpty) await emails.syncEmails(_acc.id, 'Work');
  }

  group('with OBJECTID', () {
    setUp(() => open(objectIds: true));
    tearDown(() => db.close());

    test('a listing stores each folder\'s MAILBOXID', () async {
      await workWith(const []);
      expect(
        {
          for (final m in await db.select(db.mailboxes).get())
            m.path: m.srvMailboxId,
        },
        {
          'INBOX': server.folders['INBOX']!.mailboxId,
          'Archive': server.folders['Archive']!.mailboxId,
          'Work': server.folders['Work']!.mailboxId,
        },
      );
      expect(server.mailboxIdStatusCount, greaterThan(0));
    });

    test(
        'an empty folder renamed under a new UIDVALIDITY is followed: its '
        'row id and the change queued for it stay', () async {
      await workWith(const []);
      final work = await folderAt('Work');
      await emails.moveEmail((await rowOfA()).id, 'Work');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.state, 'pending');
      expect(move.payload, contains('"dest":"Job"'));
      final line =
          logs.rows.singleWhere((r) => r.event == 'mailbox.renamed_elsewhere');
      expect(line.message, contains('MAILBOXID'));
      expect(line.dataJson, contains('"by":"MAILBOXID"'));
      await flush();
      expect(server.find('a@test')!.folder.path, 'Job');
      await expectConsistent();
    });

    test(
        'a rename and a move at once (neither leaf nor parent agree) is '
        'followed; the mail keeps its rows through the UIDVALIDITY change',
        () async {
      server.addFolder('Box');
      await workWith(const ['w1@test', 'w2@test']);
      final work = await folderAt('Work');
      final w1 = await mail('w1@test');
      server.renameFolder('Work', 'Box/Job', newUidValidity: true);

      await listFolders();

      expect((await folderById(work.id))!.path, 'Box/Job');
      expect((await mail('w1@test')).srvMailboxPath, 'Box/Job');
      expect(events(), isNot(contains('mailbox.listing_untrusted')));
      // The new UIDVALIDITY re-matches the cached mail (#1314).
      await emails.syncEmails(_acc.id, 'Box/Job');
      final after = await mail('w1@test');
      expect(after.id, w1.id);
      expect(after.srvMailboxPath, 'Box/Job');
      expect(
        (await db.select(db.emails).get())
            .where((e) => e.messageId == 'w2@test'),
        hasLength(1),
      );
      await expectConsistent();
    });

    test(
        'two candidates holding the same mail: the one with the id is '
        'the folder', () async {
      await workWith(const ['w1@test', 'w2@test']);
      final work = await folderAt('Work');
      server.renameFolder('Work', 'Job', newUidValidity: true);
      // Another client also filled a sibling with copies of the same mail.
      server.addFolder('Work-copy');
      server
        ..deliver('Work-copy', 'w1@test')
        ..deliver('Work-copy', 'w2@test');

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      expect(await folderAt('Work-copy'), isNot(work));
      await expectConsistent();
    });

    test(
        'a new folder with exactly the cached mail but another id is no '
        'rename: the change queued for the gone folder fails', () async {
      await workWith(const ['w1@test', 'w2@test']);
      final work = await folderAt('Work');
      await emails.moveEmail((await rowOfA()).id, 'Work');
      // Copied into a new sibling, then deleted: the Message-ID rule alone
      // would take it for a rename.
      server.addFolder('Work-2026');
      server
        ..deliver('Work-2026', 'w1@test')
        ..deliver('Work-2026', 'w2@test')
        ..deleteFolder('Work');

      await listFolders();

      expect(await folderById(work.id), isNull);
      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(
        (move.state, move.lastError),
        ('failed', 'folder removed on the server'),
      );
      await expectConsistent();
    });

    test('a parent renamed with its subfolder: both keep their rows', () async {
      server
        ..addFolder('Work')
        ..addFolder('Work/2026');
      await listFolders();
      final work = await folderAt('Work');
      final sub = await folderAt('Work/2026');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      expect((await folderById(sub.id))!.path, 'Job/2026');
      expect(
        logs.rows.where((r) => r.event == 'mailbox.renamed_elsewhere'),
        hasLength(1),
      );
      await expectConsistent();
    });

    test(
        'a role folder renamed elsewhere is followed, so the listing is '
        'trusted (#1312)', () async {
      await listFolders();
      final archive = await folderAt('Archive');
      server.renameFolder('Archive', 'Old Mail', newUidValidity: true);

      await listFolders();

      final row = (await folderById(archive.id))!;
      expect((row.path, row.role), ('Old Mail', 'archive'));
      expect(events(), isNot(contains('mailbox.listing_untrusted')));
      await expectConsistent();
    });

    test('a folder with a queued delete is not followed, even by its id',
        () async {
      await workWith(const []);
      await rig.mailboxes.deleteMailbox(_acc.id, 'Work');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();

      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      expect(events(), contains('mailbox.delete_found_done'));
      expect(server.folders.keys, contains('Job'));
    });

    test(
        'a folder no listing read the id of yet keeps the old rules '
        '(UIDVALIDITY), but not to a folder another one\'s id names', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      await db.customStatement(
        'UPDATE mailboxes SET srv_mailbox_id = NULL WHERE path = ?',
        ['Work'],
      );
      server.renameFolder('Work', 'Job');

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      expect(
        logs.rows
            .singleWhere((r) => r.event == 'mailbox.renamed_elsewhere')
            .dataJson,
        contains('"by":"UIDVALIDITY"'),
      );
      expect((await folderById(work.id))!.srvMailboxId, isNotNull);
    });

    test(
        'a server that advertises OBJECTID but refuses the MAILBOXID item: '
        'plain STATUS, asked once per connection', () async {
      server.refusesMailboxIdStatus = true;
      server.deliver('Archive', 'more@test');

      await listFolders();

      expect(server.mailboxIdStatusCount, 1);
      expect((await folderAt('Archive')).totalCount, 2);
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.srvMailboxId),
        everyElement(isNull),
      );
    });
  });

  group('without OBJECTID', () {
    setUp(() => open(objectIds: false));
    tearDown(() => db.close());

    test(
        'no MAILBOXID asked or stored; an empty folder renamed under a new '
        'UIDVALIDITY is not followed (unchanged)', () async {
      await workWith(const []);
      await emails.moveEmail((await rowOfA()).id, 'Work');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();

      expect(server.mailboxIdStatusCount, 0);
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.srvMailboxId),
        everyElement(isNull),
      );
      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.state, 'failed');
    });

    test(
        'a folder renamed under a new UIDVALIDITY with its mail is still '
        'followed by its Message-IDs', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      expect(
        logs.rows
            .singleWhere((r) => r.event == 'mailbox.renamed_elsewhere')
            .dataJson,
        contains('"by":"Message-ID"'),
      );
    });
  });
}
