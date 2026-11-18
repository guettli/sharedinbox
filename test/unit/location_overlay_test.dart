// The `location` overlay (SYNC-REDESIGN.md §2–§5, phase 4a) on IMAP: the
// folder a mail shows in is `COALESCE(local_mailbox_path, srv_mailbox_path)`
// (empty when hidden), a delete for good hides the row instead of deleting
// it, and sync no longer deletes a row the user still has a change for.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show removeLocalMailbox;

import 'db_test_helper.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  setUp(() async {
    // No Trash folder: a delete is a delete for good.
    logs = await openRigWithMailA(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22},
      folders: [('INBOX', 'inbox'), ('Archive', 'archive')],
    );
  });
  tearDown(() => db.close());

  Future<List<PendingChangeRow>> ops() => db.select(db.pendingChanges).get();
  Future<void> expectConsistent() async =>
      expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  Future<void> sync(String folder) => emails.syncEmails(_account.id, folder);
  Future<void> flush() => emails.flushPendingChanges(_account.id, 'pw');
  Future<List<String>> threadFolders() async => [
        for (final t in await db.select(db.threads).get())
          if (t.emailIdsJson.contains((await rowOfA()).id)) t.mailboxPath,
      ];

  test('a queued move folds: the mail shows in the destination', () async {
    final id = (await rowOfA()).id;

    await emails.moveEmail(id, 'Archive');

    final e = await rowOfA();
    expect(e.mailboxPath, 'Archive');
    expect(e.localMailboxPath, 'Archive');
    expect(e.srvMailboxPath, 'INBOX', reason: 'srv_ is what the server said');
    expect(await threadFolders(), ['Archive']);
    await expectConsistent();
  });

  test(
      'a sync of the source while the move is queued keeps the mail where '
      'the user put it', () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');
    // Not flushed: a full FETCH of INBOX (no checkpoint) reads it there.
    await (db.delete(db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .go();

    await sync('INBOX');

    final e = await rowOfA();
    expect(e.id, id);
    expect(e.mailboxPath, 'Archive');
    expect(e.srvMailboxPath, 'INBOX');
    await expectConsistent();
  });

  test('an applied move is acked and dropped by the read of its destination',
      () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');
    await flush();

    var e = await rowOfA();
    expect(server.find('a@test')!.folder.path, 'Archive');
    expect(e.srvMailboxPath, 'Archive', reason: 'COPYUID relocated it');
    expect(e.mailboxPath, 'Archive');
    expect((await ops()).single.state, 'acked');
    await expectConsistent();

    await sync('Archive');

    e = await rowOfA();
    expect(await ops(), isEmpty);
    expect(e.localMailboxPath, isNull);
    expect(e.mailboxPath, 'Archive');
    await expectConsistent();
  });

  test('a refused move stops folding: the mail shows in its source again',
      () async {
    final id = (await rowOfA()).id;
    server.refuses = (messageId) => messageId == 'a@test';
    await emails.moveEmail(id, 'Archive');

    await flush();

    final e = await rowOfA();
    expect((await ops()).single.state, 'failed');
    expect(e.mailboxPath, 'INBOX');
    expect(e.localMailboxPath, isNull);
    expect(await threadFolders(), ['INBOX']);
    await expectConsistent();
  });

  test(
      'a delete for good hides the row until the server confirms it is '
      'gone', () async {
    final id = (await rowOfA()).id;

    await emails.deleteEmail(id);

    var e = await rowOfA();
    expect(e.mailboxPath, '', reason: 'hidden, not deleted');
    expect(e.localHidden, isTrue);
    expect(await emails.getEmail(id), isNull);
    expect(await threadFolders(), isEmpty);
    await expectConsistent();

    await flush();

    expect(server.find('a@test'), isNull);
    e = await rowOfA();
    expect(e.srvGone, isTrue);
    expect((await ops()).single.state, 'acked');
    await expectConsistent();

    await sync('INBOX');

    expect(await rowsOfA(), isEmpty, reason: 'clean-up rule: no op left');
    expect(await ops(), isEmpty);
  });

  test(
      'cancelling a queued delete (Undo) shows the row again, body and '
      'all', () async {
    final id = (await rowOfA()).id;
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(emailId: id, textBody: const Value('b')),
        );
    final (_, captured) = await emails.captureOps(() => emails.deleteEmail(id));

    expect((await rowOfA()).mailboxPath, '');
    expect(await emails.cancelOps(captured[id]!), hasLength(1));

    final e = await rowOfA();
    expect(e.mailboxPath, 'INBOX');
    expect(e.localHidden, isFalse);
    expect(
      (await db.select(db.emailBodies).getSingle()).textBody,
      'b',
      reason: 'a hidden row keeps its body',
    );
    expect(await threadFolders(), ['INBOX']);
    await expectConsistent();
  });

  test(
      'a mail gone on the server while the user has a move queued is kept '
      'and the change surfaces as failed (#1239)', () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');
    server.expungeElsewhere('a@test');

    await sync('INBOX');

    final e = await rowOfA();
    expect(e.srvGone, isTrue);
    expect(e.mailboxPath, 'Archive', reason: 'the queued move still shows');
    expect((await ops()).single.state, 'pending');
    expect(
      logs.rows.map((r) => r.event),
      contains('email.server_gone_with_changes'),
    );
    await expectConsistent();

    await flush();

    final change = (await ops()).single;
    expect(change.state, 'failed', reason: 'never dropped silently');
    final failed = await emails.observeFailedMutations(_account.id).first;
    expect(failed.single.id, change.id);
    expect(failed.single.failed, isTrue);
    await expectConsistent();
  });

  test(
      'a refused delete for good shows the mail again: it was hidden, not '
      'deleted', () async {
    final id = (await rowOfA()).id;
    server.refuses = (messageId) => messageId == 'a@test';
    await emails.deleteEmail(id);
    expect((await rowOfA()).mailboxPath, '');

    await flush();

    final e = await rowOfA();
    expect((await ops()).single.state, 'failed');
    expect(e.mailboxPath, 'INBOX');
    expect(e.localHidden, isFalse);
    expect(await threadFolders(), ['INBOX']);
    await expectConsistent();
  });

  test(
      'a folder removed on the server: a mail moved into it shows in its '
      'source again, its move listed as failed (#1239)', () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');

    await removeLocalMailbox(db, _account.id, 'Archive');

    final e = await rowOfA();
    expect(e.mailboxPath, 'INBOX', reason: 'where the server still has it');
    final change = (await ops()).single;
    expect(change.state, 'failed');
    expect(await threadFolders(), ['INBOX']);
    final filler = await (db.select(db.emails)
          ..where((t) => t.messageId.equals('filler@test')))
        .get();
    expect(filler, isEmpty, reason: 'gone with the folder, no change of it');
    await expectConsistent();
  });

  test('a mail deleted elsewhere without a change of the user is removed',
      () async {
    server.expungeElsewhere('a@test');

    await sync('INBOX');

    expect(await rowsOfA(), isEmpty);
    expect(await db.select(db.threads).get(), hasLength(1));
  });

  test(
      'a FETCH answer that predates a move sent meanwhile does not bring '
      'the mail back (#1269, now by the acked move)', () async {
    final id = (await rowOfA()).id;
    // A full FETCH of INBOX (no checkpoint), whose answer is fixed before
    // the user's move is sent and relocated.
    await (db.delete(db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .go();
    server.beforeAnswer = (command) async {
      if (!command.startsWith('FETCH headers')) return;
      server.beforeAnswer = null;
      await emails.moveEmail(id, 'Archive');
      await flush();
    };

    await sync('INBOX');

    final rows = await rowsOfA();
    expect(rows.map((e) => e.id), [id], reason: 'no second row in INBOX');
    expect(rows.single.mailboxPath, 'Archive');
    await expectConsistent();
  });

  test('a folder rename moves the queued changes and the rows along', () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');

    await EmailStateWriter(db).renameFolder(_account.id, 'Archive', 'Old');

    final e = await rowOfA();
    expect(e.mailboxPath, 'Old');
    expect(e.localMailboxPath, 'Old');
    expect((await ops()).single.payload, contains('"dest":"Old"'));
    await expectConsistent();
  });

  test('the consistency check finds a folder out of line and repairs it',
      () async {
    final id = (await rowOfA()).id;
    await db.customStatement(
      "UPDATE emails SET mailbox_path = 'Archive' WHERE id = ?",
      [id],
    );

    final problems = await EmailStateWriter(db).consistencyProblems();
    expect(problems.single.fields, ['mailbox_path']);

    await EmailStateWriter(db).checkSample(_account.id);

    expect((await rowOfA()).mailboxPath, 'INBOX');
    await expectConsistent();
  });
}
