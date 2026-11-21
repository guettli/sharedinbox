// A folder rename or move queued offline whose folder another IMAP client
// renamed or moved meanwhile (#1329): the flush runs before the folder
// listing, so the op used to be refused ("the folder no longer exists on
// the server") although the listing right after follows the folder by its
// MAILBOXID (#1315). The op now waits for that one listing and is then
// sent to where the folder is; only when the listing does not follow it is
// the op refused, visibly.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;
  late List<String> kicks;
  late StreamSubscription<String> kickSub;
  Future<void> open({required bool objectIds}) async {
    logs = await openRigWithMailA(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22},
      folders: [('INBOX', 'inbox'), ('Archive', 'archive')],
      objectIds: objectIds,
    );
    kicks = [];
    kickSub = emails.onChangesQueued.listen(kicks.add);
  }

  Future<void> close() async {
    await kickSub.cancel();
    await db.close();
  }

  Future<void> listFolders() => rig.mailboxes.syncMailboxes(_acc.id);
  Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
  // One sync cycle: the flush first, then the folder listing.
  Future<void> cycle() async {
    await flush();
    await listFolders();
  }

  Iterable<String> events() => logs.rows.map((r) => r.event);
  Future<MailboxRow?> folderById(String id) =>
      MailboxStateWriter(db).rowById(id);
  Future<MailboxRow> folderAt(String path) async =>
      (await db.select(db.mailboxes).get()).singleWhere((m) => m.path == path);
  Future<PendingChangeRow> folderOp() async =>
      (await rigOps()).singleWhere((o) => o.resourceType == 'Mailbox');
  Future<void> expectConsistent() async {
    expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
    expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
  }

  // Another client renames Clients/Acme to [to] (a new UIDVALIDITY, as
  // Stalwart gives it; the MAILBOXID stays).
  void acmeRenamedTo(String to) =>
      server.renameFolder('Clients/Acme', to, newUidValidity: true);

  // Clients/Acme (with [mail] in it, synced) below Clients, listed.
  Future<MailboxRow> acme({List<String> mail = const []}) async {
    server
      ..addFolder('Clients')
      ..addFolder('Clients/Acme');
    for (final id in mail) {
      server.deliver('Clients/Acme', id);
    }
    await listFolders();
    if (mail.isNotEmpty) await emails.syncEmails(_acc.id, 'Clients/Acme');
    return folderAt('Clients/Acme');
  }

  group('with OBJECTID', () {
    setUp(() => open(objectIds: true));
    tearDown(close);

    test(
        'an offline rename of a folder another client renamed waits for the '
        'listing, then renames the followed folder (#1329)', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      // Another client renames the same folder while the app is offline.
      acmeRenamedTo('Clients/Acme2');

      await flush();

      // Not refused: it waits, uncharged, and the loop is kicked.
      final waiting = await folderOp();
      expect((waiting.state, waiting.attempts), ('pending', 0));
      expect(events(), isNot(contains('pending_change.rejected')));
      expect(events(), contains('mailbox.op_waits_for_listing'));
      expect(kicks, contains(_acc.id));

      await listFolders();
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(events(), contains('mailbox.renamed_elsewhere'));

      await cycle();

      expect(server.folders.keys, contains('Clients/AcmeCorp'));
      expect(server.folders.keys, isNot(contains('Clients/Acme2')));
      expect(
        server.folderCommands.where((c) => c.startsWith('RENAME')),
        [
          'RENAME Clients/Acme->Clients/AcmeCorp',
          'RENAME Clients/Acme2->Clients/AcmeCorp',
        ],
      );
      final renamed = (await folderById(folder.id))!;
      expect((renamed.path, renamed.name), ('Clients/AcmeCorp', 'AcmeCorp'));
      expect(
        (await rigOps()).where((o) => o.state == 'failed'),
        isEmpty,
      );
      expect(events(), isNot(contains('pending_change.rejected')));
      final followed = logs.rows
          .singleWhere((r) => r.event == 'pending_change.folder_followed');
      expect(followed.dataJson, contains('"from":"Clients/Acme"'));
      expect(followed.dataJson, contains('"path":"Clients/Acme2"'));
      await expectConsistent();
    });

    test(
        'a mail move into the folder waits with the rename and lands in the '
        'renamed folder', () async {
      await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      await emails.moveEmail((await rowOfA()).id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await cycle();
      await cycle();

      expect(server.find('a@test')!.folder.path, 'Clients/AcmeCorp');
      expect(
        (await rigOps()).where((o) => o.state == 'failed'),
        isEmpty,
      );
      expect(events(), isNot(contains('pending_change.dest_missing')));
      expect(events(), isNot(contains('pending_change.rejected')));
      await expectConsistent();
    });

    test(
        'renamed and moved elsewhere at once: the rename follows it to the '
        'new parent', () async {
      final folder = await acme(mail: const ['c1@test']);
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Archive/Acme');

      await cycle();
      await cycle();

      expect(server.folders.keys, contains('Archive/AcmeCorp'));
      expect((await folderById(folder.id))!.path, 'Archive/AcmeCorp');
      expect(server.find('c1@test')!.folder.path, 'Archive/AcmeCorp');
      expect(events(), isNot(contains('pending_change.rejected')));
      await expectConsistent();
    });

    test(
        'an offline folder move of a folder renamed elsewhere moves the '
        'followed folder', () async {
      final folder = await acme();
      await rig.mailboxes.moveMailbox(
        _acc.id,
        'Clients/Acme',
        newParentDisplayPath: 'Archive',
      );
      acmeRenamedTo('Clients/Acme2');

      await flush();
      expect((await folderOp()).state, 'pending');
      await listFolders();
      await cycle();

      expect(server.folders.keys, contains('Archive/Acme2'));
      expect((await folderById(folder.id))!.path, 'Archive/Acme2');
      expect(events(), contains('pending_change.folder_followed'));
      expect(events(), isNot(contains('pending_change.rejected')));
      await expectConsistent();
    });

    test(
        'a folder move into a parent renamed elsewhere waits, then moves '
        'into the followed parent', () async {
      server.addFolder('Work');
      final folder = await acme();
      await rig.mailboxes.moveMailbox(
        _acc.id,
        'Work',
        newParentDisplayPath: 'Clients/Acme',
      );
      acmeRenamedTo('Clients/Acme2');

      await cycle();
      await cycle();

      expect(server.folders.keys, contains('Clients/Acme2/Work'));
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(events(), isNot(contains('pending_change.rejected')));
      await expectConsistent();
    });

    test(
        'a folder deleted elsewhere: the rename waits one listing, which '
        'removes the folder and fails the rename visibly', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      server.deleteFolder('Clients/Acme');

      await flush();
      expect((await folderOp()).state, 'pending');
      await listFolders();

      expect(await folderById(folder.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      // The mark goes with the failure: a Retry waits one listing again.
      expect(op.payload, isNot(contains('goneAt')));
      expect(events(), contains('pending_change.folder_removed'));
      expect(events(), isNot(contains('pending_change.folder_followed')));

      await cycle();
      expect(server.folders.keys, isNot(contains('Clients/AcmeCorp')));
      await expectConsistent();
    });

    test(
        'a listing that keeps the folder but does not follow it: the next '
        'flush refuses the rename visibly (one listing bounds the wait)',
        () async {
      final archive = await folderAt('Archive');
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      // A role folder a listing leaves out is kept (#1312).
      server.deleteFolder('Archive');

      await flush();
      expect((await folderOp()).state, 'pending');
      await listFolders();
      expect(await folderById(archive.id), isNotNull);
      final kicked = kicks.length;

      await flush();

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no longer exists on the server'));
      expect(events(), contains('pending_change.rejected'));
      expect(
        server.folderCommands.where((c) => c.startsWith('RENAME')),
        hasLength(2),
      );
      // No second kick: nothing loops.
      expect(kicks.length, kicked);
      // The user's Retry waits for one listing again.
      expect(op.payload, isNot(contains('goneAt')));
      await emails.retryMutation(op.id);
      await flush();
      expect((await folderOp()).state, 'pending');
    });

    test(
        'a rename that may have reached the server (answer lost) is not '
        'sent to where another client renamed the folder since: refused '
        'visibly', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      // Our RENAME reached the server but its answer was lost; then another
      // client renamed the folder on to AcmeCorp2.
      server.renameFolder(
        'Clients/Acme',
        'Clients/AcmeCorp2',
        newUidValidity: true,
      );
      await db.customStatement(
        'UPDATE pending_changes SET attempts = 1 '
        "WHERE resource_type = 'Mailbox'",
      );

      await cycle();
      await cycle();

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no longer exists on the server'));
      expect(events(), contains('pending_change.rejected'));
      expect(events(), isNot(contains('mailbox.op_waits_for_listing')));
      // The other client's rename stays: no RENAME back to AcmeCorp.
      expect(
        server.folderCommands.where((c) => c.startsWith('RENAME')),
        ['RENAME Clients/Acme->Clients/AcmeCorp'],
      );
      expect(server.folders.keys, contains('Clients/AcmeCorp2'));
      expect((await folderById(folder.id))!.path, 'Clients/AcmeCorp2');
    });

    test(
        'a listing that started while the rename was being sent does not '
        'count: the op is not refused on it and waits for the next one',
        () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');
      var listed = false;
      // The LIST the flush reads after the refused RENAME: the op is still
      // claimed.
      server.beforeAnswer = (command) async {
        if (listed || !command.startsWith('LIST')) return;
        if (!server.folderCommands.any((c) => c.startsWith('RENAME'))) return;
        listed = true;
        // Another isolate's listing while the op is claimed: it takes the
        // op for moving and follows nothing.
        await listFolders();
      };

      await flush();
      server.beforeAnswer = null;

      expect(listed, isTrue);
      expect((await folderOp()).state, 'pending');
      await flush();
      expect((await folderOp()).state, 'pending');
      expect(events(), isNot(contains('pending_change.rejected')));
      await listFolders();
      await cycle();

      // Left open: that listing stored Clients/Acme2 as a second row with
      // the folder's MAILBOXID, so the next one does not follow the old row
      // onto it (no row is merged into another): the rename fails visibly,
      // and nothing is sent to a wrong path.
      expect(await folderById(folder.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      expect(events(), contains('pending_change.folder_removed'));
      expect(
        server.folderCommands.where((c) => c.startsWith('RENAME')),
        everyElement(startsWith('RENAME Clients/Acme->')),
      );
      expect(server.folders.keys, contains('Clients/Acme2'));
    });

    test(
        'while folder listings keep failing the op waits at most 24 hours, '
        'then is refused visibly', () async {
      await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await flush();
      now = now.add(const Duration(hours: 23));
      await flush();
      expect((await folderOp()).state, 'pending');
      now = now.add(const Duration(hours: 2));
      await flush();

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no longer exists on the server'));
      expect(events(), contains('pending_change.rejected'));
    });

    test('a delete of a folder renamed elsewhere is unchanged: done', () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await cycle();

      expect(
        server.folderCommands.where((c) => c.startsWith('DELETE')),
        isEmpty,
      );
      expect(server.folders.keys, contains('Clients/Acme2'));
      expect(await folderById(folder.id), isNull);
      expect(events(), isNot(contains('mailbox.op_waits_for_listing')));
    });
  });

  group('without OBJECTID', () {
    setUp(() => open(objectIds: false));
    tearDown(close);

    test(
        'a folder renamed elsewhere with its mail is followed by its '
        'Message-IDs: the rename goes there (was refused)', () async {
      final folder = await acme(mail: const ['c1@test']);
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await cycle();
      await cycle();

      expect(server.folders.keys, contains('Clients/AcmeCorp'));
      expect((await folderById(folder.id))!.path, 'Clients/AcmeCorp');
      expect(events(), isNot(contains('pending_change.rejected')));
      await expectConsistent();
    });

    test(
        'an empty folder renamed elsewhere cannot be recognised: the rename '
        'fails visibly after the listing (unchanged)', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await cycle();

      expect(await folderById(folder.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      expect(events(), contains('pending_change.folder_removed'));
      await cycle();
      expect(server.folders.keys, isNot(contains('Clients/AcmeCorp')));
    });
  });
}
