// A folder another IMAP client renamed or moved is followed by its RFC 8474
// MAILBOXID when the server gives folder ids (#1315): an empty folder under
// a new UIDVALIDITY, a rename and a move at once, two candidates. Ids that
// differ are never matched by contents; without OBJECTID the UIDVALIDITY /
// Message-ID rules stay as they were.

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

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
  Future<void> forgetId(String path) => db.customStatement(
        'UPDATE mailboxes SET srv_mailbox_id = NULL WHERE path = ?',
        [path],
      );
  final byPattern = RegExp(r'"by":"([^"]+)"');
  List<String?> renamedBy() => [
        for (final r in logs.rows)
          if (r.event == 'mailbox.renamed_elsewhere')
            byPattern.firstMatch(r.dataJson ?? '')?.group(1),
      ];
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

  // Folders A and B with a mail each, synced, and a@test's move into A
  // queued.
  Future<({MailboxRow a, MailboxRow b})> foldersAAndB() async {
    server
      ..addFolder('A')
      ..deliver('A', 'a1@test')
      ..addFolder('B')
      ..deliver('B', 'b1@test');
    await listFolders();
    await emails.syncEmails(_acc.id, 'A');
    await emails.syncEmails(_acc.id, 'B');
    final a = await folderAt('A');
    final b = await folderAt('B');
    await emails.moveEmail((await rowOfA()).id, 'A');
    return (a: a, b: b);
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
        '(UIDVALIDITY)', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      await forgetId('Work');
      server.renameFolder('Work', 'Job');

      await listFolders();

      expect((await folderById(work.id))!.path, 'Job');
      expect(renamedBy(), ['UIDVALIDITY']);
      expect((await folderById(work.id))!.srvMailboxId, isNotNull);
    });

    test(
        'a folder without a stored id is not matched by contents to a new '
        "folder another gone folder's id names", () async {
      // Work (no stored id) and Other (with one) hold the same mail.
      server
        ..addFolder('Work')
        ..deliver('Work', 'w@test')
        ..addFolder('Other')
        ..deliver('Other', 'w@test');
      await listFolders();
      await emails.syncEmails(_acc.id, 'Work');
      await emails.syncEmails(_acc.id, 'Other');
      final work = await folderAt('Work');
      final other = await folderAt('Other');
      await forgetId('Work');
      // Work goes; Other is renamed next to where Work was. By contents
      // alone Work2 would be Work's too, and the two matches would cancel
      // each other out.
      server
        ..deleteFolder('Work')
        ..renameFolder('Other', 'Work2', newUidValidity: true);

      await listFolders();

      expect((await folderById(other.id))!.path, 'Work2');
      expect(await folderById(work.id), isNull);
      expect(renamedBy(), ['MAILBOXID']);
      await expectConsistent();
    });

    test(
        'a gone folder with a stored id is not followed by contents to a new '
        'folder with another id, even with its UIDVALIDITY and mail', () async {
      await workWith(const ['w1@test', 'w2@test']);
      final work = await folderAt('Work');
      // Another folder with Work's UIDVALIDITY and mail, but its own id.
      final old = server.folders.remove('Work')!;
      server.folders['Job'] =
          FakeServerFolder('Job', old.uidValidity, mailboxId: 'F-other')
            ..messages.addAll(old.messages)
            ..uidNext = old.uidNext;

      await listFolders();

      expect(await folderById(work.id), isNull);
      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      await expectConsistent();
    });

    test(
        'a rename queued here and one done elsewhere: the folder follows its '
        "id, and the flush renames it to the user's name", () async {
      await workWith(const []);
      final work = await folderAt('Work');
      await rig.mailboxes.renameMailbox(_acc.id, 'Work', 'Mine');
      server.renameFolder('Work', 'Job', newUidValidity: true);

      await listFolders();
      expect((await folderById(work.id))!.path, 'Job');
      await flush();
      await listFolders();

      final row = (await folderById(work.id))!;
      expect((row.path, row.name), ('Mine', 'Mine'));
      expect(server.folders['Mine']!.mailboxId, row.srvMailboxId);
      expect(server.folders.keys, isNot(contains('Job')));
      await expectConsistent();
    });

    test(
        'two folders that swapped names elsewhere: each row follows its id, '
        'with its mail and the change queued for it', () async {
      final (:a, :b) = await foldersAAndB();
      server
        ..renameFolder('A', 'tmp')
        ..renameFolder('B', 'A')
        ..renameFolder('tmp', 'B');

      await listFolders();

      expect((await folderById(a.id))!.path, 'B');
      expect((await folderById(b.id))!.path, 'A');
      expect((await mail('a1@test')).srvMailboxPath, 'B');
      expect((await mail('b1@test')).srvMailboxPath, 'A');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.payload, contains('"dest":"B"'));
      expect(renamedBy(), ['MAILBOXID', 'MAILBOXID']);
      expect(events(), isNot(contains('mailbox.id_changed')));
      await flush();
      expect(server.find('a@test')!.folder.path, 'B');
      await expectConsistent();
    });

    test(
        'a folder deleted elsewhere and another renamed onto its name: the '
        'old row goes (its queued move fails), the renamed one takes the path',
        () async {
      final (:a, :b) = await foldersAAndB();
      server
        ..deleteFolder('A')
        ..renameFolder('B', 'A');

      await listFolders();

      expect(await folderById(a.id), isNull);
      expect((await folderById(b.id))!.path, 'A');
      expect((await mail('b1@test')).srvMailboxPath, 'A');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(
        (move.state, move.lastError),
        ('failed', 'folder removed on the server'),
      );
      expect(renamedBy(), ['MAILBOXID']);
      await expectConsistent();
    });

    test(
        'a folder deleted and made again elsewhere under its name: the row '
        'stays, says so, and its mail is matched again', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      final w = await mail('w@test');
      server
        ..deleteFolder('Work')
        ..addFolder('Work')
        ..deliver('Work', 'w@test');

      await listFolders();

      final row = (await folderById(work.id))!;
      expect(row.srvMailboxId, server.folders['Work']!.mailboxId);
      expect(events(), contains('mailbox.id_changed'));
      await emails.syncEmails(_acc.id, 'Work');
      expect((await mail('w@test')).id, w.id);
      expect(events(), contains('sync.uidvalidity_changed'));
      await expectConsistent();
    });

    test(
        'a subfolder moved out on its own while its parent was renamed and a '
        'new folder took its old name below: it follows its id', () async {
      server
        ..addFolder('P')
        ..addFolder('P/S')
        ..addFolder('X');
      await listFolders();
      final p = await folderAt('P');
      final sub = await folderAt('P/S');
      server
        ..renameFolder('P/S', 'X/S')
        ..renameFolder('P', 'Q')
        ..addFolder('Q/S');

      await listFolders();

      expect((await folderById(p.id))!.path, 'Q');
      expect((await folderById(sub.id))!.path, 'X/S');
      final newSub = await folderAt('Q/S');
      expect(newSub.id, isNot(sub.id));
      expect(newSub.srvMailboxId, server.folders['Q/S']!.mailboxId);
      await expectConsistent();
    });

    test(
        'a role guessed by name does not follow a renamed folder when a new '
        'folder has that name', () async {
      await listFolders();
      final archive = await folderAt('Archive');
      server
        ..renameFolder('Archive', 'Old Archive', newUidValidity: true)
        ..addFolder('Archive');

      await listFolders();

      expect((await folderById(archive.id))!.path, 'Old Archive');
      expect((await folderById(archive.id))!.role, isNull);
      expect((await folderAt('Archive')).role, 'archive');
      expect(
        (await db.select(db.mailboxes).get()).where((m) => m.role == 'archive'),
        hasLength(1),
      );
    });

    test(
        'a chain of renames (B to C, A to B) while the STATUS of C fails: '
        'nothing is removed or merged; the next listing follows both',
        () async {
      final (:a, :b) = await foldersAAndB();
      server
        ..renameFolder('B', 'C', newUidValidity: true)
        ..renameFolder('A', 'B', newUidValidity: true)
        ..statusError = (path) => path == 'C' ? 'NO try later' : null;

      await listFolders();

      expect((await folderById(a.id))!.path, 'A');
      expect((await folderById(b.id))!.path, 'B');
      expect((await folderById(b.id))!.srvMailboxId, isNot(a.srvMailboxId));
      expect((await mail('b1@test')).srvMailboxPath, 'B');
      expect(events(), contains('mailbox.listing_untrusted'));
      expect(events(), isNot(contains('mailbox.removed_gone')));
      expect(events(), isNot(contains('mailbox.local_merged')));
      expect((await rigOps()).map((o) => o.state), isNot(contains('failed')));

      server.statusError = null;
      await listFolders();

      expect((await folderById(a.id))!.path, 'B');
      expect((await folderById(b.id))!.path, 'C');
      expect((await mail('b1@test')).srvMailboxPath, 'C');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.state, 'pending');
      expect(move.payload, contains('"dest":"B"'));
      await expectConsistent();
    });

    test(
        'ids refused part way through a listing: no folder is removed for a '
        'missing id, none stored, the listing is not trusted', () async {
      final (:a, :b) = await foldersAAndB();
      server
        ..renameFolder('B', 'C', newUidValidity: true)
        ..renameFolder('A', 'B', newUidValidity: true)
        ..refusesMailboxIdFor = (path) => path == 'B';

      await listFolders();

      expect(events(), contains('mailbox.mailbox_ids_refused'));
      expect((await folderById(b.id))!.path, 'B');
      expect((await folderById(b.id))!.srvMailboxId, b.srvMailboxId);
      expect(await folderById(a.id), isNotNull);
      expect(events(), contains('mailbox.listing_untrusted'));
      expect(events(), isNot(contains('mailbox.removed_gone')));
    });

    test(
        "a parent's subfolders wait for a row that moves out of their way "
        '(B/x moved to D, then A with A/x renamed to B)', () async {
      server
        ..addFolder('A')
        ..addFolder('A/x')
        ..deliver('A/x', 'ax@test')
        ..addFolder('B/x')
        ..deliver('B/x', 'bx@test');
      await listFolders();
      await emails.syncEmails(_acc.id, 'A/x');
      await emails.syncEmails(_acc.id, 'B/x');
      final aRow = await folderAt('A');
      final ax = await folderAt('A/x');
      final bx = await folderAt('B/x');
      server
        ..renameFolder('B/x', 'D')
        ..renameFolder('A', 'B');

      await listFolders();

      expect((await folderById(aRow.id))!.path, 'B');
      expect((await folderById(ax.id))!.path, 'B/x');
      expect((await folderById(bx.id))!.path, 'D');
      expect((await mail('ax@test')).srvMailboxPath, 'B/x');
      expect((await mail('bx@test')).srvMailboxPath, 'D');
      expect(events(), isNot(contains('mailbox.local_merged')));
      await expectConsistent();
    });

    test('a parent and its subfolder swapped with another pair', () async {
      server
        ..addFolder('A')
        ..addFolder('A/s')
        ..deliver('A/s', 'as@test')
        ..addFolder('B')
        ..addFolder('B/s')
        ..deliver('B/s', 'bs@test');
      await listFolders();
      await emails.syncEmails(_acc.id, 'A/s');
      await emails.syncEmails(_acc.id, 'B/s');
      final ids = {
        for (final p in ['A', 'A/s', 'B', 'B/s']) p: (await folderAt(p)).id,
      };
      server
        ..renameFolder('A', 'tmp')
        ..renameFolder('B', 'A')
        ..renameFolder('tmp', 'B');

      await listFolders();

      expect(
        {for (final e in ids.entries) e.key: (await folderById(e.value))!.path},
        {'A': 'B', 'A/s': 'B/s', 'B': 'A', 'B/s': 'A/s'},
      );
      expect((await mail('as@test')).srvMailboxPath, 'B/s');
      expect((await mail('bs@test')).srvMailboxPath, 'A/s');
      expect(events(), isNot(contains('mailbox.local_merged')));
      expect(
        logs.rows.where((r) => '${r.message}${r.dataJson}'.contains('aside')),
        isEmpty,
      );
      await expectConsistent();
    });

    test('three folders that rotated names: each row follows its id', () async {
      for (final p in ['A', 'B', 'C']) {
        server
          ..addFolder(p)
          ..deliver(p, '${p.toLowerCase()}1@test');
      }
      await listFolders();
      for (final p in ['A', 'B', 'C']) {
        await emails.syncEmails(_acc.id, p);
      }
      final ids = {
        for (final p in ['A', 'B', 'C']) p: (await folderAt(p)).id,
      };
      await emails.moveEmail((await rowOfA()).id, 'A');
      server
        ..renameFolder('A', 'tmp')
        ..renameFolder('C', 'A')
        ..renameFolder('B', 'C')
        ..renameFolder('tmp', 'B');

      await listFolders();

      expect(
        {for (final e in ids.entries) e.key: (await folderById(e.value))!.path},
        {'A': 'B', 'B': 'C', 'C': 'A'},
      );
      expect((await mail('a1@test')).srvMailboxPath, 'B');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.payload, contains('"dest":"B"'));
      final renamed = [
        for (final r in logs.rows)
          if (r.event == 'pending_change.folder_renamed') r.dataJson ?? '',
      ];
      expect(renamed, isNotEmpty);
      expect(renamed.where((d) => d.contains('aside')), isEmpty);
      await flush();
      expect(server.find('a@test')!.folder.path, 'B');
      await expectConsistent();
    });

    test(
        'a replaced folder with a delete queued: its delete counts as done, '
        'the folder now at its path and the renamed one stay', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      await rig.mailboxes.deleteMailbox(_acc.id, 'Work', removeEmails: true);
      server
        ..renameFolder('Work', 'Job', newUidValidity: true)
        ..addFolder('Work');

      await listFolders();
      await flush();

      expect(await folderById(work.id), isNull);
      expect(events(), contains('mailbox.delete_found_done'));
      expect(server.folderCommands, isEmpty);
      expect(server.folders.keys, containsAll(['Work', 'Job']));
      // The new folder under the old name: stored once the delete settled.
      await listFolders();
      final now = await folderAt('Work');
      expect(now.srvMailboxId, server.folders['Work']!.mailboxId);
      await expectConsistent();
    });

    test(
        'a connection lost during the STATUS round stops the listing before '
        'anything is followed or pruned', () async {
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      server
        ..renameFolder('Work', 'Job', newUidValidity: true)
        ..dropsAtStatus = (path) => path == 'Job';

      await expectLater(listFolders(), throwsA(anything));

      expect((await folderById(work.id))!.path, 'Work');
      expect((await mail('w@test')).srvMailboxPath, 'Work');
      expect(events(), isNot(contains('mailbox.removed_gone')));

      server.dropsAtStatus = null;
      await listFolders();
      expect((await folderById(work.id))!.path, 'Job');
    });

    test(
        'a \\Noselect folder answers no STATUS but does not keep a listing in '
        'doubt: a folder deleted and made again elsewhere takes its new id',
        () async {
      server.addFolder('Shared').noSelect = true;
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      server
        ..deleteFolder('Work')
        ..addFolder('Work')
        ..addFolder('New');

      await listFolders();

      expect(
        (await folderById(work.id))!.srvMailboxId,
        server.folders['Work']!.mailboxId,
      );
      expect(events(), contains('mailbox.id_changed'));
      expect(events(), isNot(contains('mailbox.listing_untrusted')));
      expect(events(), isNot(contains('mailbox.listing_skipped_unsure')));
      expect((await folderAt('New')).srvMailboxId, isNotNull);
    });

    test(
        'a selectable folder whose STATUS always fails: a replaced folder '
        'keeps its id for a while, then takes the new one; a new folder with '
        'an unknown id is stored meanwhile', () async {
      server
        ..addFolder('Bad')
        ..statusError = (path) => path == 'Bad' ? 'NO broken' : null;
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      final oldId = work.srvMailboxId;
      server
        ..deleteFolder('Work')
        ..addFolder('Work')
        ..addFolder('Fresh');

      await listFolders();
      expect((await folderById(work.id))!.srvMailboxId, oldId);
      expect(events(), isNot(contains('mailbox.id_changed')));
      expect(
        (await folderAt('Fresh')).srvMailboxId,
        server.folders['Fresh']!.mailboxId,
      );

      now = now.add(const Duration(hours: 1));
      await listFolders();
      expect((await folderById(work.id))!.srvMailboxId, oldId);
      await listFolders();

      expect(
        (await folderById(work.id))!.srvMailboxId,
        server.folders['Work']!.mailboxId,
      );
      expect(events(), contains('mailbox.id_changed'));
      logs.rows.clear();
      await listFolders();
      expect(events(), isNot(contains('mailbox.listing_skipped_unsure')));
      expect(events(), isNot(contains('mailbox.id_changed')));
    });

    test(
        'moves that cannot all be made (a swap whose path a moving parent '
        'would take a gone subfolder to) are not made: no row is left on a '
        'stand-in path or merged', () async {
      server
        ..addFolder('Q/c')
        ..addFolder('Z')
        ..addFolder('P')
        ..addFolder('P/c');
      await listFolders();
      final before = {
        for (final m in await db.select(db.mailboxes).get()) m.id: m.path,
      };
      server
        ..deleteFolder('P/c')
        ..renameFolder('Q/c', 'tmp')
        ..renameFolder('Z', 'Q/c')
        ..renameFolder('tmp', 'Z')
        ..renameFolder('P', 'Q');

      await listFolders();

      final rows = await db.select(db.mailboxes).get();
      expect(rows.where((m) => m.path.startsWith('\u0001')), isEmpty);
      for (final MapEntry(key: id, value: path) in before.entries) {
        expect((await folderById(id))?.path, path);
      }
      expect(events(), isNot(contains('mailbox.local_merged')));
      expect(events(), contains('mailbox.listing_untrusted'));
      await expectConsistent();
    });

    test(
        'the put-back of rows left on a stand-in path takes only a row on the '
        'one it took: a subfolder carried along stays with its parent',
        () async {
      // Row ids are built from paths: "Work/2026" carried along below
      // "Work"'s stand-in path ends with its own id too.
      for (final p in ['Work', 'Work/2026', 'P', 'X']) {
        server.addFolder(p);
      }
      await listFolders();
      final work = await folderAt('Work');
      final sub = await folderAt('Work/2026');
      final p = await folderAt('P');
      final x = await folderAt('X');
      // Moves no listing gives (X twice): P steps aside, X takes P, Work
      // steps aside, P takes Work. Work is left aside with both its path
      // and its target taken: the defensive put-back.
      await MailboxStateWriter(db).serverPathsChanged(_acc.id, [
        (p.id, 'Work'),
        (x.id, 'P'),
        (work.id, 'P'),
        (x.id, 'X2'),
      ]);

      final workNow = (await folderById(work.id))!.path;
      expect(workNow, startsWith('\u0001'));
      expect((await folderById(sub.id))!.path, '$workNow/2026');
      expect((await folderById(p.id))!.path, 'Work');
      expect(
        (await db.select(db.mailboxes).get())
            .where((m) => m.path.startsWith('Work/')),
        isEmpty,
      );
    });

    test(
        'a listing in which no folder is replaced clears the marks of '
        'replaced folders: a folder replaced again waits from the start',
        () async {
      server
        ..addFolder('Bad')
        ..statusError = (path) => path == 'Bad' ? 'NO broken' : null;
      await workWith(const ['w@test']);
      final work = await folderAt('Work');
      final oldId = work.srvMailboxId;
      server
        ..deleteFolder('Work')
        ..addFolder('Work');
      Future<SyncStateRow?> marks() async =>
          (await db.select(db.syncStates).get())
              .where((s) => s.resourceType == 'Mailbox:PendingReplace')
              .firstOrNull;

      await listFolders();
      expect(await marks(), isNotNull);

      // "Work" answers no id now: nothing is replaced.
      server.statusError =
          (path) => path == 'Bad' || path == 'Work' ? 'NO broken' : null;
      await listFolders();
      expect(await marks(), isNull);

      server.statusError = (path) => path == 'Bad' ? 'NO broken' : null;
      now = now.add(const Duration(hours: 1));
      await listFolders();
      await listFolders();
      await listFolders();

      // Three listings, but not an hour since it was replaced again.
      expect((await folderById(work.id))!.srvMailboxId, oldId);
      expect(events(), isNot(contains('mailbox.id_changed')));
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
