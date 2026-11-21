// A folder rename or move queued offline whose folder another IMAP client
// renamed or moved meanwhile (#1329): the flush runs before the folder
// listing, so the op used to be refused ("the folder no longer exists on
// the server") although the listing right after follows the folder by its
// MAILBOXID (#1315). The op now waits for that one listing and is then
// sent to where the folder is; only when the listing does not follow it is
// the op refused, visibly.

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'helpers/folder_follow_rig.dart';
import 'helpers/stateful_imap_rig.dart';

const _acc = statefulRigAccount;

void main() {
  final f = FolderFollowRig.forSuite();
  Future<MailboxRow?> folderById(String id) =>
      MailboxStateWriter(db).rowById(id);
  Future<MailboxRow> folderAt(String path) async =>
      (await db.select(db.mailboxes).get()).singleWhere((m) => m.path == path);
  Future<PendingChangeRow> folderOp() async =>
      (await rigOps()).singleWhere((o) => o.resourceType == 'Mailbox');
  // Another client renames Clients/Acme to [to] (a new UIDVALIDITY, as
  // Stalwart gives it; the MAILBOXID stays).
  void acmeRenamedTo(String to) =>
      server.renameFolder('Clients/Acme', to, newUidValidity: true);
  // The folder DELETEs the app sent.
  List<String> deletes() => [
        for (final c in server.folderCommands)
          if (c.startsWith('DELETE')) c,
      ];

  // Clients/Acme (with [mail] in it, synced) below Clients, listed.
  Future<MailboxRow> acme({List<String> mail = const []}) async {
    server
      ..addFolder('Clients')
      ..addFolder('Clients/Acme');
    for (final id in mail) {
      server.deliver('Clients/Acme', id);
    }
    await rigListFolders();
    if (mail.isNotEmpty) await emails.syncEmails(_acc.id, 'Clients/Acme');
    return folderAt('Clients/Acme');
  }

  group('with OBJECTID', () {
    f.use(objectIds: true);

    test(
        'an offline rename of a folder another client renamed waits for the '
        'listing, then renames the followed folder (#1329)', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      // Another client renames the same folder while the app is offline.
      acmeRenamedTo('Clients/Acme2');

      await rigFlush();

      // Not refused: it waits, uncharged, and the loop is kicked.
      final waiting = await folderOp();
      expect((waiting.state, waiting.attempts), ('pending', 0));
      expect(f.events(), isNot(contains('pending_change.rejected')));
      expect(f.events(), contains('mailbox.op_waits_for_listing'));
      expect(f.kicks, contains(_acc.id));

      await rigListFolders();
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(f.events(), contains('mailbox.renamed_elsewhere'));

      await rigCycle();

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
      expect(f.events(), isNot(contains('pending_change.rejected')));
      final followed = f.logs.rows
          .singleWhere((r) => r.event == 'pending_change.folder_followed');
      expect(followed.dataJson, contains('"from":"Clients/Acme"'));
      expect(followed.dataJson, contains('"path":"Clients/Acme2"'));
      await expectRigConsistent();
    });

    test(
        'a mail move into the folder waits with the rename and lands in the '
        'renamed folder', () async {
      await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      await emails.moveEmail((await rowOfA()).id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await rigCycle();
      await rigCycle();

      expect(server.find('a@test')!.folder.path, 'Clients/AcmeCorp');
      expect(
        (await rigOps()).where((o) => o.state == 'failed'),
        isEmpty,
      );
      expect(f.events(), isNot(contains('pending_change.dest_missing')));
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await expectRigConsistent();
    });

    test(
        'renamed and moved elsewhere at once: the rename follows it to the '
        'new parent', () async {
      final folder = await acme(mail: const ['c1@test']);
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Archive/Acme');

      await rigCycle();
      await rigCycle();

      expect(server.folders.keys, contains('Archive/AcmeCorp'));
      expect((await folderById(folder.id))!.path, 'Archive/AcmeCorp');
      expect(server.find('c1@test')!.folder.path, 'Archive/AcmeCorp');
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await expectRigConsistent();
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

      await rigFlush();
      expect((await folderOp()).state, 'pending');
      await rigListFolders();
      await rigCycle();

      expect(server.folders.keys, contains('Archive/Acme2'));
      expect((await folderById(folder.id))!.path, 'Archive/Acme2');
      expect(f.events(), contains('pending_change.folder_followed'));
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await expectRigConsistent();
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

      await rigCycle();
      await rigCycle();

      expect(server.folders.keys, contains('Clients/Acme2/Work'));
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await expectRigConsistent();
    });

    test(
        'a folder deleted elsewhere: the rename waits one listing, which '
        'removes the folder and fails the rename visibly', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      server.deleteFolder('Clients/Acme');

      await rigFlush();
      expect((await folderOp()).state, 'pending');
      await rigListFolders();

      expect(await folderById(folder.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      // The mark goes with the failure: a Retry waits one listing again.
      expect(op.payload, isNot(contains('goneAt')));
      expect(f.events(), contains('pending_change.folder_removed'));
      expect(f.events(), isNot(contains('pending_change.folder_followed')));

      await rigCycle();
      expect(server.folders.keys, isNot(contains('Clients/AcmeCorp')));
      await expectRigConsistent();
    });

    test(
        'a listing in doubt that keeps the folder does not end the wait; the '
        'one that confirms the folder gone fails the rename visibly', () async {
      final archive = await folderAt('Archive');
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      // A role folder a listing leaves out is kept (#1312): the listing is
      // not trusted.
      server.deleteFolder('Archive');

      await rigFlush();
      expect((await folderOp()).state, 'pending');
      await rigListFolders();
      expect(await folderById(archive.id), isNotNull);
      final kicked = f.kicks.length;

      await rigFlush();

      // Not refused on a listing in doubt (#1339): it waits on.
      expect((await folderOp()).state, 'pending');
      expect(f.events(), isNot(contains('pending_change.rejected')));
      // No second kick: nothing loops.
      expect(f.kicks.length, kicked);

      // The next listing asks about the marked folder: gone, removed, and
      // the rename fails visibly.
      await rigListFolders();
      expect(await folderById(archive.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      expect(op.payload, isNot(contains('goneAt')));
    });

    test(
        'a follow the listing wrote after the op was read is kept when the '
        'op is settled from that read (no stale payload written back)',
        () async {
      server.addFolder('Work');
      await acme();
      await rig.mailboxes.moveMailbox(
        _acc.id,
        'Work',
        newParentDisplayPath: 'Clients/Acme',
      );
      acmeRenamedTo('Clients/Acme2');
      await rigFlush();
      final read = await folderOp();
      expect(read.payload, contains('goneAt'));

      // A listing (another isolate's) follows the parent meanwhile.
      await rigListFolders();
      expect((await folderOp()).payload, contains('"parent":"Clients/Acme2"'));
      await MailboxStateWriter(db).waitForListing(read, 'Clients/Acme');

      final stored = await folderOp();
      expect(stored.payload, contains('"parent":"Clients/Acme2"'));
      expect(stored.payload, isNot(contains('goneAt')));
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

      await rigCycle();
      await rigCycle();

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no longer exists on the server'));
      expect(f.events(), contains('pending_change.rejected'));
      expect(f.events(), isNot(contains('mailbox.op_waits_for_listing')));
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
        await rigListFolders();
      };

      await rigFlush();
      server.beforeAnswer = null;

      expect(listed, isTrue);
      expect((await folderOp()).state, 'pending');
      await rigFlush();
      expect((await folderOp()).state, 'pending');
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await rigListFolders();
      await rigCycle();

      // #1341: that listing did not store Clients/Acme2 as a second row
      // with the folder's MAILBOXID (which the next listing could not
      // follow the old row onto): it left it to the next listing, which
      // followed the folder there, and the rename went through.
      expect(f.events(), contains('mailbox.listing_skipped_followable'));
      final renamed = (await folderById(folder.id))!;
      expect((renamed.path, renamed.name), ('Clients/AcmeCorp', 'AcmeCorp'));
      // The flushes while it waited tried the old path (refused, uncharged);
      // the last RENAME goes to where the folder is.
      final renames =
          server.folderCommands.where((c) => c.startsWith('RENAME')).toList();
      expect(renames.last, 'RENAME Clients/Acme2->Clients/AcmeCorp');
      expect(
        renames.take(renames.length - 1),
        everyElement('RENAME Clients/Acme->Clients/AcmeCorp'),
      );
      expect(server.folders.keys, contains('Clients/AcmeCorp'));
      expect(server.folders.keys, isNot(contains('Clients/Acme2')));
      expect((await rigOps()).where((o) => o.state == 'failed'), isEmpty);
      expect(f.events(), isNot(contains('pending_change.folder_removed')));
      // One row per folder id.
      final ids = [
        for (final m in await db.select(db.mailboxes).get())
          if (m.srvMailboxId case final id?) id,
      ];
      expect(ids.toSet(), hasLength(ids.length));
      await expectRigConsistent();
    });

    test(
        'a listing while the op is claimed stores no second row for the '
        'folder: the new path waits for the next listing (#1341)', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');
      // The rename being sent (claimed) while another isolate lists.
      await db.customStatement(
        "UPDATE pending_changes SET state = 'inflight' "
        "WHERE resource_type = 'Mailbox'",
      );

      await rigListFolders();

      final paths = (await db.select(db.mailboxes).get()).map((m) => m.path);
      expect(paths, isNot(contains('Clients/Acme2')));
      expect((await folderById(folder.id))!.path, 'Clients/Acme');
      expect(f.events(), contains('mailbox.listing_skipped_followable'));

      // The op back in the queue (never sent): the next listing follows
      // the folder onto the new path, the same row.
      await db.customStatement(
        "UPDATE pending_changes SET state = 'pending' "
        "WHERE resource_type = 'Mailbox'",
      );
      await rigListFolders();
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(
        (await db.select(db.mailboxes).get())
            .where((m) => m.path == 'Clients/Acme2'),
        hasLength(1),
      );
    });

    test(
        'while folder listings keep failing the op waits at most 24 hours, '
        'then is refused visibly', () async {
      await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await flushPastListingWaitCap(() async => (await folderOp()).state);

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no longer exists on the server'));
      expect(f.events(), contains('pending_change.rejected'));
    });

    test(
        'an offline delete of a folder another client renamed waits for the '
        'listing, follows the folder by its MAILBOXID and deletes it there '
        '(#1340; was counted as done, the folder came back)', () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await rigFlush();

      final waiting = await folderOp();
      expect((waiting.state, waiting.attempts), ('pending', 0));
      expect(f.events(), contains('mailbox.op_waits_for_listing'));
      expect(f.kicks, contains(_acc.id));

      await rigListFolders();
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      expect(f.events(), contains('mailbox.delete_follows'));
      // Still hidden: the delete is queued.
      final shown = await rig.mailboxes.observeMailboxes(_acc.id).first;
      expect(shown.map((m) => m.path), isNot(contains('Clients/Acme2')));

      await rigCycle();

      expect(deletes(), ['DELETE Clients/Acme2']);
      expect(server.folders.keys, isNot(contains('Clients/Acme2')));
      expect(await folderById(folder.id), isNull);
      expect((await rigOps()).where((o) => o.state == 'failed'), isEmpty);
      final followed = f.logs.rows
          .singleWhere((r) => r.event == 'pending_change.folder_followed');
      expect(followed.dataJson, contains('"from":"Clients/Acme"'));
      expect(followed.dataJson, contains('"path":"Clients/Acme2"'));
      await expectRigConsistent();
    });

    test('a listing before the first flush takes the delete along too',
        () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await rigListFolders();
      await rigFlush();

      expect(deletes(), ['DELETE Clients/Acme2']);
      expect(await folderById(folder.id), isNull);
      expect(f.events(), contains('mailbox.delete_follows'));
      expect(f.events(), contains('pending_change.folder_followed'));
    });

    test(
        'a folder renamed elsewhere that got mail since is not deleted: the '
        'delete fails visibly, naming the new path', () async {
      final folder = await acme(mail: const ['c1@test']);
      await rig.mailboxes
          .deleteMailbox(_acc.id, 'Clients/Acme', removeEmails: true);
      acmeRenamedTo('Clients/Acme2');
      server.deliver('Clients/Acme2', 'new@test');

      await rigCycle();
      await rigCycle();

      expect(deletes(), isEmpty);
      expect(server.folders['Clients/Acme2']!.messages, hasLength(2));
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('renamed elsewhere to "Clients/Acme2"'));
      expect(op.lastError, contains('1 more mail(s)'));
      expect(f.events(), contains('pending_change.rejected'));
      // The folder shows again, at its new path, with its row.
      expect((await folderById(folder.id))!.path, 'Clients/Acme2');
      final shown = await rig.mailboxes.observeMailboxes(_acc.id).first;
      expect(shown.map((m) => m.path), contains('Clients/Acme2'));
    });

    test(
        'a folder renamed elsewhere with a new folder made at its old name: '
        'that one is never deleted; the delete follows the id', () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');
      server.addFolder('Clients/Acme');

      await rigFlush();
      expect(deletes(), isEmpty);
      expect((await folderOp()).state, 'pending');

      await rigListFolders();
      await rigFlush();

      expect(deletes(), ['DELETE Clients/Acme2']);
      expect(server.folders.keys, contains('Clients/Acme'));
      expect(await folderById(folder.id), isNull);
      await rigListFolders();
      expect(
        (await folderAt('Clients/Acme')).srvMailboxId,
        server.folders['Clients/Acme']!.mailboxId,
      );
      await expectRigConsistent();
    });

    test(
        'a delete sent before without an answer is not sent to the folder '
        'renamed elsewhere: it counts as done, logged', () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');
      await db.customStatement(
        'UPDATE pending_changes SET attempts = 1 '
        "WHERE resource_type = 'Mailbox'",
      );

      await rigCycle();
      await rigCycle();

      expect(deletes(), isEmpty);
      expect(server.folders.keys, contains('Clients/Acme2'));
      expect(await folderById(folder.id), isNull);
      expect(f.events(), contains('mailbox.delete_found_done'));
      expect(f.events(), isNot(contains('mailbox.delete_follows')));
    });

    test(
        'a folder deleted elsewhere: the delete waits one listing, which '
        'removes the folder, and counts as done', () async {
      final folder = await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      server.deleteFolder('Clients/Acme');

      await rigCycle();

      expect(await folderById(folder.id), isNull);
      expect(deletes(), isEmpty);
      expect(
        (await rigOps()).where((o) => o.state == 'failed'),
        isEmpty,
      );
      expect(f.events(), contains('mailbox.delete_found_done'));
      await expectRigConsistent();
    });
  });

  group('without OBJECTID', () {
    f.use(objectIds: false);

    test(
        'a folder renamed elsewhere with its mail is followed by its '
        'Message-IDs: the rename goes there (was refused)', () async {
      final folder = await acme(mail: const ['c1@test']);
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await rigCycle();
      await rigCycle();

      expect(server.folders.keys, contains('Clients/AcmeCorp'));
      expect((await folderById(folder.id))!.path, 'Clients/AcmeCorp');
      expect(f.events(), isNot(contains('pending_change.rejected')));
      await expectRigConsistent();
    });

    test(
        'an empty folder renamed elsewhere cannot be recognised: the rename '
        'fails visibly after the listing (unchanged)', () async {
      final folder = await acme();
      await rig.mailboxes.renameMailbox(_acc.id, 'Clients/Acme', 'AcmeCorp');
      acmeRenamedTo('Clients/Acme2');

      await rigCycle();

      expect(await folderById(folder.id), isNull);
      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      expect(f.events(), contains('pending_change.folder_removed'));
      await rigCycle();
      expect(server.folders.keys, isNot(contains('Clients/AcmeCorp')));
    });

    test(
        'an offline delete of a folder renamed elsewhere, recognised by its '
        'mail only: never followed, it fails visibly naming the new path '
        '(#1340; was counted as done)', () async {
      await acme(mail: const ['c1@test']);
      await rig.mailboxes
          .deleteMailbox(_acc.id, 'Clients/Acme', removeEmails: true);
      acmeRenamedTo('Clients/Acme2');

      await rigFlush();
      expect((await folderOp()).state, 'pending');
      await rigListFolders();

      final op = await folderOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('renamed elsewhere to "Clients/Acme2"'));
      expect(op.payload, isNot(contains('goneAt')));
      expect(f.events(), contains('mailbox.delete_not_followed'));
      expect(f.events(), isNot(contains('mailbox.delete_found_done')));
      await rigCycle();
      expect(deletes(), isEmpty);
      expect(server.folders.keys, contains('Clients/Acme2'));
      // The folder shows at its new path; the user decides.
      final shown = await rig.mailboxes.observeMailboxes(_acc.id).first;
      expect(shown.map((m) => m.path), contains('Clients/Acme2'));
    });

    test(
        'an empty folder renamed elsewhere cannot be recognised: the delete '
        'waits one listing and counts as done, logged', () async {
      await acme();
      await rig.mailboxes.deleteMailbox(_acc.id, 'Clients/Acme');
      acmeRenamedTo('Clients/Acme2');

      await rigCycle();

      expect(deletes(), isEmpty);
      expect((await rigOps()).where((o) => o.state == 'failed'), isEmpty);
      expect(f.events(), contains('mailbox.op_waits_for_listing'));
      expect(f.events(), contains('mailbox.delete_found_done'));
    });
  });
}
