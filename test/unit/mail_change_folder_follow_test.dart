// A mail change (read, star, move, snooze, delete) queued offline in a
// folder another IMAP client renamed or moved meanwhile (#1339): the flush
// runs before the folder listing, so the change met the old path gone
// (`NO [NONEXISTENT]`) and was dropped as done (`pending_change.
// skipped_gone`), or, for a move into the folder, failed (`pending_change.
// dest_missing`), although the listing right after follows the folder by
// its MAILBOXID (#1315). The change now waits for that one listing, the way
// a folder rename does (#1329), and is then sent to where the folder is;
// when the listing does not follow it, it fails visibly.

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'helpers/folder_follow_rig.dart';
import 'helpers/stateful_imap_rig.dart';

void main() {
  final f = FolderFollowRig.forSuite();
  Future<Email> mail(String messageId) =>
      (db.select(db.emails)..where((t) => t.messageId.equals(messageId)))
          .getSingle();
  Future<PendingChangeRow> mailOp() async =>
      (await rigOps()).singleWhere((o) => o.resourceType != 'Mailbox');
  Future<List<PendingChangeRow>> failed() async =>
      (await rigOps()).where((o) => o.state == 'failed').toList();
  // Work, with c1@test in it, listed and synced.
  Future<void> work() async {
    server
      ..addFolder('Work')
      ..deliver('Work', 'c1@test');
    await rigListFolders();
    await emails.syncEmails(statefulRigAccount.id, 'Work');
  }

  // Another client renames Work to [to] (a new UIDVALIDITY, as Stalwart
  // gives it; the MAILBOXID stays).
  void workRenamedTo(String to) =>
      server.renameFolder('Work', to, newUidValidity: true);

  // After the first flush: the change waits, uncharged, unsent, with an
  // App Log info line and a kick; nothing was dropped as done.
  Future<void> expectWaiting() async {
    final op = await mailOp();
    expect((op.state, op.attempts), ('pending', 0));
    expect(op.payload, contains('goneAt'));
    expect(f.events(), contains('pending_change.waits_for_listing'));
    expect(f.events(), isNot(contains('pending_change.skipped_gone')));
    expect(f.kicks, contains(statefulRigAccount.id));
  }

  // c1@test's delete queued in Work; another client renames Work to
  // Work2 before the flush, which makes the delete wait, then creates a
  // new Work holding a copy of c1@test; then a listing and a flush.
  Future<void> deleteAfterRenameAndRecreate() async {
    await work();
    await emails.deleteEmail((await mail('c1@test')).id);
    workRenamedTo('Work2');
    await rigFlush();
    await expectWaiting();
    server
      ..addFolder('Work')
      ..deliver('Work', 'c1@test');
    await rigListFolders();
    await rigFlush();
  }

  group('with OBJECTID', () {
    f.use(objectIds: true);

    test(
        'a read and a star change in a folder renamed elsewhere wait for the '
        'listing and land in the renamed folder (was dropped as done)',
        () async {
      await work();
      final id = (await mail('c1@test')).id;
      await emails.setFlag(id, seen: true);
      await emails.setFlag(id, flagged: true);
      workRenamedTo('Work2');

      await rigFlush();

      final ops = [
        for (final o in await rigOps())
          if (o.resourceType != 'Mailbox') o,
      ];
      expect(
        ops.map((o) => (o.state, o.attempts)),
        everyElement(('pending', 0)),
      );
      expect(f.events(), contains('pending_change.waits_for_listing'));
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
      expect(f.kicks, contains(statefulRigAccount.id));

      await rigListFolders();
      await rigFlush();

      final onServer = server.find('c1@test')!;
      expect(onServer.folder.path, 'Work2');
      expect(onServer.message.flags, containsAll([r'\Seen', r'\Flagged']));
      expect(await failed(), isEmpty);
      expect(f.events(), contains('pending_change.folder_followed'));
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
      await expectRigConsistent();
    });

    test('a move out of a folder renamed elsewhere lands in its destination',
        () async {
      await work();
      await emails.moveEmail((await mail('c1@test')).id, 'Archive');
      workRenamedTo('Work2');

      await rigFlush();
      await expectWaiting();
      // Shown where the user put it meanwhile.
      expect((await mail('c1@test')).mailboxPath, 'Archive');

      await rigListFolders();
      await rigCycle();

      expect(server.find('c1@test')!.folder.path, 'Archive');
      expect(await failed(), isEmpty);
      expect(
        server.hits.map((h) => h.command),
        contains('MOVE Work2->Archive'),
      );
      await expectRigConsistent();
    });

    test(
        'a move into a folder renamed elsewhere waits and lands in the '
        'renamed folder (failed as destination missing)', () async {
      await work();
      await emails.moveEmail((await rowOfA()).id, 'Work');
      workRenamedTo('Work2');

      await rigFlush();
      await expectWaiting();
      expect(f.events(), isNot(contains('pending_change.dest_missing')));

      await rigListFolders();
      await rigCycle();

      expect(server.find('a@test')!.folder.path, 'Work2');
      expect(await failed(), isEmpty);
      expect(f.events(), isNot(contains('pending_change.dest_missing')));
      await expectRigConsistent();
    });

    test('a snooze in a folder renamed elsewhere is sent from the new path',
        () async {
      await work();
      await emails.snoozeEmail((await mail('c1@test')).id, DateTime.utc(2030));
      workRenamedTo('Work2');

      await rigCycle();
      expect(
        (await rigOps()).singleWhere((o) => o.changeType == 'snooze').state,
        isNot('failed'),
      );
      await rigCycle();

      final onServer = server.find('c1@test')!;
      expect(onServer.folder.path, 'Snoozed');
      expect(
        onServer.message.flags.where((f) => f.startsWith('snz:')),
        hasLength(1),
      );
      expect(await failed(), isEmpty);
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
      await expectRigConsistent();
    });

    test('a delete in a folder renamed elsewhere expunges the mail there',
        () async {
      await work();
      await emails.deleteEmail((await mail('c1@test')).id);
      workRenamedTo('Work2');

      await rigFlush();
      await expectWaiting();
      await rigListFolders();
      await rigFlush();

      expect(server.find('c1@test'), isNull);
      expect(await failed(), isEmpty);
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
    });

    test(
        'a folder deleted elsewhere: the change waits one listing, which '
        'removes the folder and fails it visibly (was dropped as done)',
        () async {
      await work();
      await emails.setFlag((await mail('c1@test')).id, flagged: true);
      server.deleteFolder('Work');

      await rigFlush();
      await expectWaiting();
      await rigListFolders();

      final op = await mailOp();
      expect(op.state, 'failed');
      expect(op.lastError, 'folder removed on the server');
      expect(f.events(), contains('pending_change.folder_removed'));
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
      expect(f.events(), isNot(contains('pending_change.folder_followed')));

      // A Retry carries no stale mark.
      await emails.retryMutation(op.id);
      expect((await mailOp()).payload, isNot(contains('goneAt')));
    });

    test(
        'a delete whose folder was deleted elsewhere fails visibly too (not '
        'counted as done)', () async {
      await work();
      await emails.deleteEmail((await mail('c1@test')).id);
      server.deleteFolder('Work');

      await rigCycle();

      final op = await mailOp();
      expect((op.changeType, op.state), ('delete', 'failed'));
      expect(op.lastError, 'folder removed on the server');
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
    });

    test(
        'a listing that keeps the folder but does not follow it: the change '
        'fails visibly at the next flush without being sent (one listing '
        'bounds the wait)', () async {
      // A role folder a listing leaves out is kept (#1312).
      await emails.moveEmail((await rowOfA()).id, 'Archive');
      await rigFlush();
      await emails.syncEmails(statefulRigAccount.id, 'Archive');
      await emails.setFlag((await rowOfA()).id, flagged: true);
      server.deleteFolder('Archive');

      await rigFlush();
      await expectWaiting();
      await rigListFolders();
      final kicked = f.kicks.length;
      final hits = server.hits.length;

      await rigFlush();

      final op = await mailOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('did not find it renamed or moved'));
      expect(op.payload, isNot(contains('goneAt')));
      expect(f.events(), contains('pending_change.folder_not_found'));
      expect(server.hits.length, hits);
      // No second kick: nothing loops.
      expect(f.kicks.length, kicked);
    });

    test(
        'another client renamed the folder and made a new one at the old '
        'path: the change follows the folder by its id, not the path',
        () async {
      await deleteAfterRenameAndRecreate();

      // The copy in the new Work is untouched; the one in Work2 is gone.
      expect(server.find('c1@test')!.folder.path, 'Work');
      expect(server.folders['Work2']!.messages, isEmpty);
      expect(await failed(), isEmpty);
    });

    test(
        'while folder listings keep failing the change waits at most 24 '
        'hours, then fails visibly', () async {
      await work();
      await emails.setFlag((await mail('c1@test')).id, seen: true);
      workRenamedTo('Work2');

      await flushPastListingWaitCap(() async => (await mailOp()).state);

      final op = await mailOp();
      expect(op.state, 'failed');
      expect(op.lastError, contains('no folder list could be read'));
      expect(f.events(), contains('pending_change.folder_not_found'));
      expect(server.find('c1@test')!.message.flags, isNot(contains(r'\Seen')));
    });

    test('a change that may have reached the server is followed with a warn',
        () async {
      await work();
      await emails.setFlag((await mail('c1@test')).id, flagged: true);
      workRenamedTo('Work2');
      await db.customStatement(
        'UPDATE pending_changes SET attempts = 1 '
        "WHERE resource_type != 'Mailbox'",
      );

      await rigCycle();
      await rigFlush();

      expect(server.find('c1@test')!.message.flags, contains(r'\Flagged'));
      final followed = f.logs.rows
          .singleWhere((r) => r.event == 'pending_change.folder_followed');
      expect(followed.level.name, 'warn');
    });
  });

  group('without OBJECTID', () {
    f.use(objectIds: false);

    test(
        'the star follows a folder renamed elsewhere, with its mail, by the '
        'Message-IDs it holds (was dropped as done)', () async {
      await work();
      await emails.setFlag((await mail('c1@test')).id, flagged: true);
      workRenamedTo('Work2');

      await rigCycle();
      await rigFlush();

      final onServer = server.find('c1@test')!;
      expect(onServer.folder.path, 'Work2');
      expect(onServer.message.flags, contains(r'\Flagged'));
      expect(await failed(), isEmpty);
      expect(f.events(), isNot(contains('pending_change.skipped_gone')));
      await expectRigConsistent();
    });

    test(
        'renamed elsewhere and a new folder made at the old path: the delete '
        'is not sent to the new folder; it fails visibly', () async {
      await deleteAfterRenameAndRecreate();

      // Nothing expunged anywhere.
      expect(server.folders['Work']!.messages, hasLength(1));
      expect(server.folders['Work2']!.messages, hasLength(1));
      final op = await mailOp();
      expect(op.state, 'failed');
      expect(f.events(), contains('pending_change.folder_not_found'));
    });
  });
}
