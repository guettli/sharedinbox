// Folder ops offline (SYNC-REDESIGN.md §7, phase 5a; #1242): creating and
// renaming a folder are queued mailbox ops, folded into the mailbox rows
// (`local_name`), flushed before the email changes on IMAP and JMAP, with the
// same outcomes as email changes. A move into a folder created offline waits
// for the create and fails with it.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/db/mailbox_fold.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/jmap_test_server.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

Future<void> _expectConsistent(AppDatabase db) async {
  expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
}

Future<List<(String, String)>> _ops(AppDatabase db) async => [
      for (final o in await (db.select(db.pendingChanges)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get())
        (o.changeType, o.state),
    ];

void main() {
  setUpAll(configureSqliteForTests);

  group('fold', () {
    MailboxFoldOp op(int seq, String type, String name, String state) =>
        MailboxFoldOp(seq: seq, type: type, name: name, state: state);

    test('the latest foldable create or rename names the folder', () {
      expect(foldMailboxName(const []), isNull);
      expect(
        foldMailboxName([
          op(2, renameMailboxOp, 'B', 'pending'),
          op(1, createMailboxOp, 'A', 'acked'),
        ]),
        'B',
      );
      // A failed rename stops folding: the server's name shows again.
      expect(
        foldMailboxName([
          op(1, createMailboxOp, 'A', 'acked'),
          op(2, renameMailboxOp, 'B', 'failed'),
        ]),
        'A',
      );
      expect(
        localMailboxShown([op(1, createMailboxOp, 'A', 'failed')]),
        isFalse,
      );
      expect(localMailboxShown([op(1, createMailboxOp, 'A', 'stuck')]), isTrue);
    });

    test('IMAP display paths: a pending name replaces the leaf, also below',
        () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'INBOX', name: 'INBOX', srvName: 'INBOX'),
          DisplayPathRow(
            path: 'INBOX.Work',
            name: 'Job',
            srvName: 'Work',
            localName: 'Job',
          ),
          DisplayPathRow(path: 'INBOX.Work.2026', name: '2026'),
        ],
        jmap: false,
        separator: '.',
      );
      expect(paths, {
        'INBOX': 'INBOX',
        'INBOX.Work': 'INBOX.Job',
        'INBOX.Work.2026': 'INBOX.Job.2026',
      });
    });

    test(
        "IMAP display paths on a '/' server: a '.' in a name is no "
        'hierarchy', () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'Mr', name: 'Mr', srvName: 'Mr'),
          DisplayPathRow(
            path: 'Mr. Smith',
            name: 'Smith',
            srvName: 'Mr. Smith',
            localName: 'Smith',
          ),
          DisplayPathRow(
            path: 'Work',
            name: 'Job',
            srvName: 'Work',
            localName: 'Job',
          ),
          DisplayPathRow(path: 'Work.old', name: 'Work.old'),
          DisplayPathRow(path: 'Work/2026', name: '2026'),
          DisplayPathRow(path: 'Archive/2025', name: '2025'),
        ],
        jmap: false,
      );
      expect(paths, {
        'Mr': 'Mr',
        'Mr. Smith': 'Smith',
        'Work': 'Job',
        'Work.old': 'Work.old',
        'Work/2026': 'Job/2026',
        // No pending name, no cached parent: the server path as it is.
        'Archive/2025': 'Archive/2025',
      });
    });

    test('JMAP display paths: effective names along parentId', () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'p', name: 'Projects'),
          DisplayPathRow(path: '~new:1', name: '2026', parentId: 'p'),
          DisplayPathRow(path: 'c', name: 'Orphan', parentId: 'gone'),
        ],
        jmap: true,
      );
      expect(paths, {
        'p': 'Projects',
        '~new:1': 'Projects/2026',
        // An uncached parent truncates, never shows its id (#605).
        'c': 'Orphan',
      });
    });
  });

  group('IMAP', () {
    late RecordingAppLogRepository logs;

    setUp(() async => logs = await openRigInboxArchive());
    tearDown(() => db.close());

    Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
    // A flush with the network down: nothing is sent, nothing charged.
    Future<void> offlineFlush() => EmailRepositoryImpl(
          db,
          rig.accounts,
          imapConnect: (_, __, ___) =>
              Future.error(const SocketException('offline')),
        ).flushPendingChanges(_acc.id, 'pw');
    Future<List<String>> shownFolders() async => [
          for (final m in await rig.mailboxes.observeMailboxes(_acc.id).first)
            m.displayPath,
        ];
    Iterable<String> events() => logs.rows.map((r) => r.event);

    test(
        'offline: a folder created shows at once and mail moved into it '
        'waits; the next flush creates it, then moves the mail', () async {
      final folder = await rig.mailboxes.createMailbox(_acc.id, 'Projects');
      expect(folder.path, 'Projects');
      expect(await shownFolders(), contains('Projects'));
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Projects');
      expect((await rowOfA()).mailboxPath, 'Projects');

      await offlineFlush();
      expect(server.folders.keys, isNot(contains('Projects')));
      expect(
        (await db.select(db.pendingChanges).get()).map((o) => o.attempts),
        [0, 0],
      );
      await flush();

      expect(server.folderCommands, ['CREATE Projects']);
      expect(server.find('a@test')!.folder.path, 'Projects');
      final e = await rowOfA();
      expect(
        (e.id, e.mailboxPath, e.srvMailboxPath),
        (id, 'Projects', 'Projects'),
      );
      await _expectConsistent(db);

      // A folder listing confirms the create, the folder's sync the move.
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Projects');
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a refused create fails, and the move waiting for it fails with it: '
        'the mail shows in its folder again', () async {
      server.refusesFolder = (path) => path == 'Bad';
      await rig.mailboxes.createMailbox(_acc.id, 'Bad');
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Bad');

      await flush();

      expect(await _ops(db), [
        ('create_mailbox', 'failed'),
        ('move', 'failed'),
      ]);
      final move = (await db.select(db.pendingChanges).get()).last;
      expect(move.lastError, contains('could not be created'));
      expect((await rowOfA()).mailboxPath, 'INBOX');
      expect(server.find('a@test')!.folder.path, 'INBOX');
      expect(await shownFolders(), isNot(contains('Bad')));
      expect(
        events(),
        containsAll([
          'pending_change.rejected',
          'pending_change.folder_not_created',
        ]),
      );
      final failed = await emails.observeFailedMutations(_acc.id).first;
      expect(
        failed.map((f) => f.changeType),
        containsAll(['create_mailbox', 'move']),
      );
      await _expectConsistent(db);

      // Retry: the folder shows again, the move that failed with it is
      // queued again, and the next flush creates the folder and moves the
      // mail there.
      server.refusesFolder = null;
      final create = (await db.select(db.pendingChanges).get()).first;
      await emails.retryMutation(create.id);
      expect(await shownFolders(), contains('Bad'));
      expect(await _ops(db), [
        ('create_mailbox', 'pending'),
        ('move', 'pending'),
      ]);
      expect((await rowOfA()).mailboxPath, 'Bad');
      await flush();
      expect(server.folders.keys, contains('Bad'));
      expect(server.find('a@test')!.folder.path, 'Bad');
      await _expectConsistent(db);
    });

    test('a name the server has already is a failed change (no adoption)',
        () async {
      server.addFolder('Taken');
      await rig.mailboxes.createMailbox(_acc.id, 'Taken');

      await flush();

      expect(server.folderCommands, isEmpty);
      final change = await db.select(db.pendingChanges).getSingle();
      expect(change.state, 'failed');
      expect(change.lastError, contains('already exists'));
      await _expectConsistent(db);
    });

    test(
        'discarding a queued create removes the folder and fails the move '
        'waiting for it', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Later');
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Later');
      final create = (await db.select(db.pendingChanges).get()).first;

      await emails.discardMutation(create.id);

      expect(await shownFolders(), isNot(contains('Later')));
      expect(await _ops(db), [('move', 'failed')]);
      expect((await rowOfA()).mailboxPath, 'INBOX');
      await flush();
      expect(server.folderCommands, isEmpty);
      await _expectConsistent(db);
    });

    test(
        'deleting a folder created offline only gives up its creation, '
        'never asks the server', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Oops');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Oops');

      expect(await shownFolders(), isNot(contains('Oops')));
      expect(await db.select(db.pendingChanges).get(), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'offline rename shows at once; the flush renames, and the mail and '
        'the moves queued into the folder follow', () async {
      final archive = (await (db.select(db.mailboxes)
                ..where((t) => t.path.equals('Archive')))
              .getSingle())
          .id;
      final renamed =
          await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      expect((renamed.name, renamed.path), ('Old Mail', 'Archive'));
      expect(await shownFolders(), contains('Old Mail'));
      final id = (await rowOfA()).id;
      // Queued while the rename is: it names the folder by its path.
      await emails.moveEmail(id, 'Archive');

      await offlineFlush();
      expect(server.folders.keys, contains('Archive'));

      await flush();

      expect(server.folderCommands, ['RENAME Archive->Old Mail']);
      expect(server.find('a@test')!.folder.path, 'Old Mail');
      final row = await (db.select(db.mailboxes)
            ..where((t) => t.id.equals(archive)))
          .getSingle();
      expect(
        (row.path, row.name, row.srvName),
        ('Old Mail', 'Old Mail', 'Old Mail'),
      );
      final filler = await (db.select(db.emails)
            ..where((t) => t.messageId.equals('filler@test')))
          .getSingle();
      expect(filler.srvMailboxPath, 'Old Mail');
      expect(filler.mailboxPath, 'Old Mail');
      expect((await rowOfA()).mailboxPath, 'Old Mail');
      await _expectConsistent(db);

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(
        (await _ops(db)).where((o) => o.$1 == 'rename_mailbox'),
        isEmpty,
        reason: 'the listing confirmed the rename',
      );
      await _expectConsistent(db);
    });

    test(
        'a folder listing that started before the rename was confirmed '
        'neither brings the old folder back nor drops the renamed one',
        () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      var flushed = false;
      server.beforeAnswer = (command) async {
        if (flushed || !command.startsWith('LIST')) return;
        flushed = true;
        // The answer (with "Archive") is fixed; the rename lands now.
        await flush();
      };

      await rig.mailboxes.syncMailboxes(_acc.id);
      server.beforeAnswer = null;

      expect(flushed, isTrue);
      final paths = (await db.select(db.mailboxes).get()).map((m) => m.path);
      expect(paths, unorderedEquals(['INBOX', 'Old Mail']));
      expect(await _ops(db), [('rename_mailbox', 'acked')]);

      // The next listing confirms it.
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a folder another client deleted while its rename is queued: the '
        'rename fails, stays listed, and the App Log says so', () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      server.folders.remove('Archive');

      await rig.mailboxes.syncMailboxes(_acc.id);
      // Archive has a role: the first listing without it keeps it, the
      // next one removes it on the server's NONEXISTENT (#1312).
      await rig.mailboxes.syncMailboxes(_acc.id);

      final change = await db.select(db.pendingChanges).getSingle();
      expect((change.changeType, change.state), ('rename_mailbox', 'failed'));
      expect(change.lastError, 'folder removed on the server');
      expect(events(), contains('pending_change.folder_removed'));
      expect(await shownFolders(), ['INBOX']);
      await _expectConsistent(db);
    });

    test(
        'a folder another client created under the name of a never-sent '
        'create is a clash, also when a listing sees it first', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Shared');
      server.addFolder('Shared');

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(
        (await rig.mailboxes.observeMailboxes(_acc.id).first)
            .singleWhere((m) => m.path == 'Shared')
            .isLocal,
        isTrue,
        reason: 'the listing does not adopt it',
      );
      await flush();

      expect(server.folderCommands, isEmpty);
      expect(await _ops(db), [('create_mailbox', 'failed')]);
      // The server's folder shows (the next listing takes it as the
      // server's); the failed create stays listed.
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await shownFolders(), contains('Shared'));
      await _expectConsistent(db);
    });

    test(
        'a create whose answer was lost is found done by the retry: no '
        'second CREATE, settled by the next listing', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Lost');
      // The CREATE reached the server, its answer did not.
      server.addFolder('Lost');
      await db.customStatement(
        'UPDATE pending_changes SET attempts = 1 WHERE change_type = '
        "'create_mailbox'",
      );

      await flush();

      expect(server.folderCommands, isEmpty);
      expect(await _ops(db), [('create_mailbox', 'acked')]);
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a sync cycle while the create is not confirmed (transient failure) '
        'neither syncs nor removes the folder', () async {
      server.failCreates = true;
      await rig.mailboxes.createMailbox(_acc.id, 'Pending');
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Pending');

      // One cycle: flush (the CREATE fails, may pass), folder listing,
      // then every folder shown is synced, as the sync loop does.
      await flush();
      await rig.mailboxes.syncMailboxes(_acc.id);
      final shown = await rig.mailboxes.observeMailboxes(_acc.id).first;
      expect(shown.singleWhere((m) => m.path == 'Pending').isLocal, isTrue);
      for (final m in shown) {
        await emails.syncEmails(_acc.id, m.path);
      }
      // The SELECT path's folder-gone handling must not touch it either.
      await removeLocalMailbox(db, _acc.id, 'Pending');

      expect(await shownFolders(), contains('Pending'));
      final ops = await db.select(db.pendingChanges).get();
      expect(
        ops.map((o) => (o.changeType, o.state, o.attempts)),
        [('create_mailbox', 'pending', 1), ('move', 'pending', 0)],
      );
      expect((await rowOfA()).mailboxPath, 'Pending');

      server.failCreates = false;
      await flush();
      expect(server.find('a@test')!.folder.path, 'Pending');
      await _expectConsistent(db);
    });

    test(
        'a rename whose answer was lost: the listing showing it done moves '
        'the folder, nothing is pruned', () async {
      final archive = await (db.select(db.mailboxes)
            ..where((t) => t.path.equals('Archive')))
          .getSingle();
      final filler = await (db.select(db.emails)
            ..where((t) => t.messageId.equals('filler@test')))
          .getSingle();
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      // The RENAME reached the server, its answer did not.
      server.renameFolder('Archive', 'Old Mail');
      await db.customStatement(
        'UPDATE pending_changes SET attempts = 1 WHERE change_type = '
        "'rename_mailbox'",
      );
      // A newer rename does not replace the one that may have been sent.
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Older Mail');
      expect(await _ops(db), [
        ('rename_mailbox', 'pending'),
        ('rename_mailbox', 'pending'),
      ]);
      await db.customStatement(
        'DELETE FROM pending_changes WHERE id = (SELECT MAX(id) FROM '
        'pending_changes)',
      );
      await MailboxStateWriter(db).refold(archive.id);

      await rig.mailboxes.syncMailboxes(_acc.id);

      final row = await (db.select(db.mailboxes)
            ..where((t) => t.id.equals(archive.id)))
          .getSingle();
      expect((row.path, row.name), ('Old Mail', 'Old Mail'));
      final e = await (db.select(db.emails)
            ..where((t) => t.id.equals(filler.id)))
          .getSingle();
      expect(e.srvMailboxPath, 'Old Mail');
      expect(events(), contains('mailbox.rename_found_done'));
      await _expectConsistent(db);
    });

    test(
        'renaming a parent moves its subfolders and their mail; a sibling '
        "with '.' in its name on a '/' server stays", () async {
      server
        ..addFolder('Work')
        ..addFolder('Work/2026')
        ..addFolder('Work.old')
        ..deliver('Work/2026', 'w@test')
        ..deliver('Work.old', 'o@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Work/2026');
      await emails.syncEmails(_acc.id, 'Work.old');
      final child = await (db.select(db.mailboxes)
            ..where((t) => t.path.equals('Work/2026')))
          .getSingle();

      await rig.mailboxes.renameMailbox(_acc.id, 'Work', 'Job');
      expect(
        await shownFolders(),
        containsAll(['Job', 'Job/2026', 'Work.old']),
      );
      await flush();

      expect(server.folders.keys, containsAll(['Job', 'Job/2026', 'Work.old']));
      final paths = {
        for (final m in await db.select(db.mailboxes).get()) m.id: m.path,
      };
      expect(paths[child.id], 'Job/2026');
      expect(paths.values, contains('Work.old'));
      Future<Email> mail(String messageId) =>
          (db.select(db.emails)..where((t) => t.messageId.equals(messageId)))
              .getSingle();
      expect((await mail('w@test')).srvMailboxPath, 'Job/2026');
      expect((await mail('o@test')).srvMailboxPath, 'Work.old');

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.path),
        unorderedEquals(['INBOX', 'Archive', 'Job', 'Job/2026', 'Work.old']),
      );
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a folder removed on the server fails the creates of subfolders '
        'queued below it, and what waits for them', () async {
      await rig.mailboxes.syncMailboxes(_acc.id);
      await rig.mailboxes.createMailbox(
        _acc.id,
        'Sub',
        parentDisplayPath: 'Archive',
      );
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Archive/Sub');
      server.folders.remove('Archive');

      await rig.mailboxes.syncMailboxes(_acc.id);
      // Archive has a role: the first listing without it keeps it, the
      // next one removes it on the server's NONEXISTENT (#1312).
      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(await _ops(db), [
        ('create_mailbox', 'failed'),
        ('move', 'failed'),
      ]);
      expect((await rowOfA()).mailboxPath, 'INBOX');
      await flush();
      expect(server.folderCommands, isEmpty, reason: 'Archive stays gone');
      await _expectConsistent(db);
    });

    test(
        'a rename waits while a mail change naming the folder is being sent '
        'by another flush', () async {
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _acc.id,
              resourceType: 'Email',
              resourceId: (await rowOfA()).id,
              changeType: 'move',
              payload: '{"uid":1,"mailboxPath":"INBOX","dest":"Archive"}',
              createdAt: DateTime(2026),
              state: const Value('inflight'),
              leaseUntil: Value(DateTime(2099)),
              claimToken: const Value('other-flush'),
            ),
          );
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');

      await flush();

      expect(server.folderCommands, isEmpty);
      final rename = (await db.select(db.pendingChanges).get()).last;
      expect((rename.state, rename.attempts), ('pending', 0));
    });

    test(
        'a path skipped while a rename was being sent is stored by the next '
        'listing when the rename is refused (6b)', () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      // Another client renamed the folder to that name first; this rename
      // is being sent by a flush that has not answered yet.
      server.renameFolder('Archive', 'Old Mail');
      await (db.update(db.pendingChanges)
            ..where((t) => t.changeType.equals('rename_mailbox')))
          .write(
        PendingChangesCompanion(
          state: const Value('inflight'),
          claimToken: const Value('other-flush'),
          leaseUntil: Value(DateTime(2099)),
        ),
      );

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.path),
        isNot(contains('Old Mail')),
      );
      expect(events(), contains('mailbox.listing_skipped_arriving'));

      // The server refuses it (the old path is gone).
      final rename = (await db.select(db.pendingChanges).get())
          .singleWhere((o) => o.changeType == 'rename_mailbox');
      await MailboxStateWriter(db).fail(rename, 'NO [NONEXISTENT]');
      await rig.mailboxes.syncMailboxes(_acc.id);

      final shown = await shownFolders();
      expect(shown.where((p) => p == 'Old Mail'), hasLength(1));
      expect(shown, isNot(contains('Archive')));
      await _expectConsistent(db);
    });

    test(
        'a listing that shows a rename done while it is being sent stores '
        'no second folder; the ack renames the folder (6b)', () async {
      final archive = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Archive');
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');

      var listed = false;
      server.beforeAnswer = (command) async {
        if (listed || !command.startsWith('RENAME')) return;
        listed = true;
        await rig.mailboxes.syncMailboxes(_acc.id);
        expect(
          (await db.select(db.mailboxes).get()).map((m) => m.path),
          isNot(contains('Old Mail')),
        );
        expect(
          (await shownFolders()).where((p) => p == 'Old Mail'),
          hasLength(1),
        );
      };
      await flush();
      server.beforeAnswer = null;

      expect(listed, isTrue);
      final renamed = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Old Mail');
      expect(renamed.id, archive.id);
      final shown = await shownFolders();
      expect(shown.where((p) => p == 'Old Mail'), hasLength(1));
      expect(shown, isNot(contains('Archive')));
      expect(events(), isNot(contains('mailbox.local_merged')));
      await _expectConsistent(db);
    });

    test('a removed folder leaves no acked op of it behind', () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      await flush();
      expect(await _ops(db), [('rename_mailbox', 'acked')]);
      server.folders.remove('Old Mail');

      await rig.mailboxes.syncMailboxes(_acc.id);
      // Archive has a role: the first listing without it keeps it, the
      // next one removes it on the server's NONEXISTENT (#1312).
      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test('an acked rename a listing contradicts twice is dropped and logged',
        () async {
      final writer = MailboxStateWriter(db, appLogger: AppLogger(logs));
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      await flush();
      // Another client renamed it right after ours; our listings see the
      // folder at the same path under another name (as JMAP would).
      final row = await (db.select(db.mailboxes)
            ..where((t) => t.path.equals('Old Mail')))
          .getSingle();
      Future<void> listing(String name) async => writer.writeServer(
            accountId: _acc.id,
            path: 'Old Mail',
            name: name,
            role: row.role,
            parentId: null,
            unreadCount: 0,
            totalCount: 0,
            unreadSeq: 0,
            readSeq: await EmailStateWriter(db).nextReadSeq(),
          );

      await listing('Elsewhere');
      expect(await _ops(db), [('rename_mailbox', 'acked')]);
      expect(
        (await db.select(db.mailboxes).get())
            .singleWhere((m) => m.path == 'Old Mail')
            .name,
        'Old Mail',
        reason: 'one contradicting read is not enough',
      );
      await listing('Elsewhere');
      expect(await _ops(db), isEmpty);
      expect(
        (await db.select(db.mailboxes).get())
            .singleWhere((m) => m.path == 'Old Mail')
            .name,
        'Elsewhere',
      );
      await pumpEventQueue();
      expect(events(), contains('op.contradicted'));
    });
  });

  group('fold (5b)', () {
    test('the latest foldable move gives the parent; a foldable delete hides',
        () {
      MailboxFoldOp op(int seq, String type, String state, {String? parent}) =>
          MailboxFoldOp(
            seq: seq,
            type: type,
            name: null,
            state: state,
            parent: parent,
          );
      expect(foldMailboxParent(const []), isNull);
      expect(
        foldMailboxParent([
          op(2, moveMailboxOp, 'pending', parent: ''),
          op(1, moveMailboxOp, 'acked', parent: 'Archive'),
        ]),
        '',
      );
      expect(
        foldMailboxParent([
          op(1, moveMailboxOp, 'acked', parent: 'Archive'),
          op(2, moveMailboxOp, 'failed', parent: 'Other'),
        ]),
        'Archive',
      );
      expect(foldMailboxHidden([op(1, deleteMailboxOp, 'stuck')]), isTrue);
      expect(foldMailboxHidden([op(1, deleteMailboxOp, 'failed')]), isFalse);
      expect(
        mailboxReadAgrees(
          op(1, moveMailboxOp, 'acked', parent: ''),
          'Work',
        ),
        isTrue,
        reason: 'top level: no server parent',
      );
      expect(
        mailboxReadAgrees(
          op(1, moveMailboxOp, 'acked', parent: 'Archive'),
          'Work',
          srvParent: 'Other',
        ),
        isFalse,
      );
    });

    test(
        'IMAP display paths: a pending move puts the folder and its '
        'subfolders below the new parent', () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'Archive', name: 'Archive'),
          DisplayPathRow(path: 'Work', name: 'Work', localParent: 'Archive'),
          DisplayPathRow(path: 'Work/2026', name: '2026'),
          DisplayPathRow(
            path: 'Archive/Old',
            name: 'Old',
            localParent: '',
          ),
        ],
        jmap: false,
      );
      expect(paths, {
        'Archive': 'Archive',
        'Work': 'Archive/Work',
        'Work/2026': 'Archive/Work/2026',
        'Archive/Old': 'Old',
      });
    });
  });

  group('IMAP move and delete (5b)', () {
    late RecordingAppLogRepository logs;

    setUp(() async => logs = await openRigInboxArchive());
    tearDown(() => db.close());

    Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
    Future<void> offlineFlush() => EmailRepositoryImpl(
          db,
          rig.accounts,
          imapConnect: (_, __, ___) =>
              Future.error(const SocketException('offline')),
        ).flushPendingChanges(_acc.id, 'pw');
    Future<List<String>> shownFolders() async => [
          for (final m in await rig.mailboxes.observeMailboxes(_acc.id).first)
            m.displayPath,
        ];
    Iterable<String> events() => logs.rows.map((r) => r.event);
    Future<MailboxRow> folder(String id) =>
        (db.select(db.mailboxes)..where((t) => t.id.equals(id))).getSingle();
    Future<Email> mail(String messageId) =>
        (db.select(db.emails)..where((t) => t.messageId.equals(messageId)))
            .getSingle();

    Future<void> addWork() async {
      server
        ..addFolder('Work')
        ..addFolder('Work/2026')
        ..deliver('Work/2026', 'w@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Work/2026');
    }

    test(
        'offline move shows the folder and its subfolders below the new '
        'parent at once; the flush renames it on the server; ids stay',
        () async {
      await addWork();
      final work = await rig.mailboxes.observeMailboxes(_acc.id).first.then(
            (all) => all.singleWhere((m) => m.path == 'Work'),
          );
      final child = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Work/2026');

      final moved = await rig.mailboxes
          .moveMailbox(_acc.id, 'Work', newParentDisplayPath: 'Archive');
      expect(moved.displayPath, 'Archive/Work');
      expect(
        await shownFolders(),
        containsAll(['Archive/Work', 'Archive/Work/2026']),
      );
      await offlineFlush();
      expect(server.folderCommands, isEmpty);

      await flush();

      expect(server.folderCommands, ['RENAME Work->Archive/Work']);
      expect((await folder(work.id)).path, 'Archive/Work');
      expect((await folder(child.id)).path, 'Archive/Work/2026');
      expect((await mail('w@test')).srvMailboxPath, 'Archive/Work/2026');
      expect(await _ops(db), [('move_mailbox', 'acked')]);
      await _expectConsistent(db);

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      expect(
        await shownFolders(),
        containsAll(['Archive/Work', 'Archive/Work/2026']),
      );
      await _expectConsistent(db);
    });

    test(
        'a listing that shows a move done while it is being sent stores no '
        'second folder; the ack moves the folder there (6b)', () async {
      await addWork();
      final rows = await db.select(db.mailboxes).get();
      final work = rows.singleWhere((m) => m.path == 'Work');
      final child = rows.singleWhere((m) => m.path == 'Work/2026');
      await rig.mailboxes
          .moveMailbox(_acc.id, 'Work', newParentDisplayPath: 'Archive');

      var listed = false;
      server.beforeAnswer = (command) async {
        if (listed || !command.startsWith('RENAME')) return;
        listed = true;
        // The RENAME is done on the server, its answer is not back yet: a
        // listing now has the new paths only.
        await rig.mailboxes.syncMailboxes(_acc.id);
        expect(
          (await db.select(db.mailboxes).get()).map((m) => m.path),
          isNot(anyOf(contains('Archive/Work'), contains('Archive/Work/2026'))),
        );
        final shown = await shownFolders();
        expect(shown.where((p) => p == 'Archive/Work'), hasLength(1));
        expect(shown.where((p) => p == 'Archive/Work/2026'), hasLength(1));
      };
      await flush();
      server.beforeAnswer = null;

      expect(listed, isTrue);
      expect((await folder(work.id)).path, 'Archive/Work');
      expect((await folder(child.id)).path, 'Archive/Work/2026');
      final shown = await shownFolders();
      expect(shown.where((p) => p == 'Archive/Work'), hasLength(1));
      expect(shown.where((p) => p == 'Archive/Work/2026'), hasLength(1));
      expect(events(), isNot(contains('mailbox.local_merged')));
      expect(events(), isNot(contains('pending_change.folder_removed')));
      await _expectConsistent(db);

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      expect((await mail('w@test')).mailboxPath, 'Archive/Work/2026');
      await _expectConsistent(db);
    });

    test(
        'an open thread drops the mail of a folder deleted (queued) at once; '
        'the hidden folders are observable (6b)', () async {
      await addWork();
      final threadId = (await mail('w@test')).threadId;
      expect(threadId, isNotNull);
      final seen = <List<String?>>[];
      final sub = emails
          .observeThreadAcrossFolders(_acc.id, threadId!)
          .listen((mails) => seen.add([for (final m in mails) m.messageId]));
      addTearDown(sub.cancel);
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 400 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(done(), isTrue);
      }

      await until(() => seen.isNotEmpty);
      expect(seen.last, ['w@test']);
      expect(await rig.mailboxes.observeHiddenFolders().first, isEmpty);

      await rig.mailboxes.deleteMailbox(_acc.id, 'Work/2026');

      // Only `mailboxes.local_hidden` changed: the query re-runs anyway.
      await until(() => seen.last.isEmpty);
      expect(
        await rig.mailboxes.observeHiddenFolders().first,
        {(accountId: _acc.id, path: 'Work/2026')},
      );
    });

    test(
        'a listing while the move is being sent prunes neither the folder '
        'nor its subfolders', () async {
      await addWork();
      await rig.mailboxes
          .moveMailbox(_acc.id, 'Work', newParentDisplayPath: 'Archive');
      // The RENAME reached the server, the flush has not settled it yet.
      server.renameFolder('Work', 'Archive/Work');
      await (db.update(db.pendingChanges)
            ..where((t) => t.changeType.equals('move_mailbox')))
          .write(
        PendingChangesCompanion(
          state: const Value('inflight'),
          claimToken: const Value('other-flush'),
          leaseUntil: Value(DateTime(2099)),
        ),
      );

      await rig.mailboxes.syncMailboxes(_acc.id);

      final paths = (await db.select(db.mailboxes).get()).map((m) => m.path);
      expect(paths, containsAll(['Work', 'Work/2026']));
      expect(
        await db.select(db.emails).get(),
        contains(predicate<Email>((e) => e.messageId == 'w@test')),
      );
      expect(events(), isNot(contains('pending_change.folder_removed')));
    });

    test(
        'offline delete hides the folder at once (lists, sync); the flush '
        'deletes it; a stale listing does not bring it back', () async {
      server.addFolder('Old');
      await rig.mailboxes.syncMailboxes(_acc.id);
      final old = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Old');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Old');

      expect(await shownFolders(), isNot(contains('Old')));
      expect((await folder(old.id)).localHidden, isTrue);
      // A hidden folder is not synced (nothing selected, nothing changes).
      await emails.syncEmails(_acc.id, 'Old');
      expect((await folder(old.id)).localHidden, isTrue);
      await offlineFlush();
      expect(server.folders.keys, contains('Old'));

      var flushed = false;
      server.beforeAnswer = (command) async {
        if (flushed || !command.startsWith('LIST')) return;
        flushed = true;
        // The listing's answer (with "Old") is fixed; the delete lands now.
        await flush();
      };
      await rig.mailboxes.syncMailboxes(_acc.id);
      server.beforeAnswer = null;

      expect(flushed, isTrue);
      expect(server.folderCommands, ['DELETE Old']);
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.path),
        isNot(contains('Old')),
      );
      expect(await _ops(db), [('delete_mailbox', 'acked')]);
      await _expectConsistent(db);

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a delete waits for the mail changes queued before it: the mail '
        'moved out is moved first, then the folder goes, in one flush',
        () async {
      server
        ..addFolder('Box')
        ..deliver('Box', 'b@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Box');
      await emails.moveEmail((await mail('b@test')).id, 'INBOX');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Box');
      await flush();

      expect(server.find('b@test')!.folder.path, 'INBOX');
      expect(server.folders.keys, isNot(contains('Box')));
      expect((await mail('b@test')).mailboxPath, 'INBOX');
      await _expectConsistent(db);
    });

    test(
        'a folder that has mail on the server is not deleted without the '
        "user's yes: a failed change, the folder shows again; Discard",
        () async {
      server
        ..addFolder('Full')
        ..deliver('Full', 'f@test');
      await rig.mailboxes.syncMailboxes(_acc.id);

      // The cached count said 0 (not synced): no removeEmails.
      await rig.mailboxes.deleteMailbox(_acc.id, 'Full');
      await flush();

      final change = await db.select(db.pendingChanges).getSingle();
      expect((change.changeType, change.state), ('delete_mailbox', 'failed'));
      expect(change.lastError, contains('not empty'));
      expect(server.find('f@test')!.folder.path, 'Full');
      expect(await shownFolders(), contains('Full'));
      expect(events(), contains('pending_change.rejected'));
      await _expectConsistent(db);

      await emails.discardMutation(change.id);
      expect(await db.select(db.pendingChanges).get(), isEmpty);
      expect(await shownFolders(), contains('Full'));
      await _expectConsistent(db);
    });

    test(
        'with removeEmails the folder goes with its mail; a mail change '
        'queued after the delete naming it fails, listed', () async {
      server
        ..addFolder('Junkish')
        ..deliver('Junkish', 'j@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Junkish');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Junkish', removeEmails: true);
      // A stale screen moves a mail into it after the delete.
      await emails.moveEmail((await rowOfA()).id, 'Junkish');
      await flush();

      expect(server.folders.keys, isNot(contains('Junkish')));
      expect(server.find('a@test')!.folder.path, 'INBOX');
      final move = (await db.select(db.pendingChanges).get())
          .singleWhere((o) => o.changeType == 'move');
      expect((move.state, move.lastError), ('failed', 'folder deleted'));
      expect((await rowOfA()).mailboxPath, 'INBOX');
      expect(events(), contains('pending_change.folder_removed'));
      await _expectConsistent(db);
    });

    test(
        'Undo before the flush cancels a delete (nothing reaches the '
        'server); after it, a move is moved back', () async {
      server.addFolder('Keep');
      await rig.mailboxes.syncMailboxes(_acc.id);
      final keep = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Keep');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Keep');
      expect(await rig.mailboxes.undoFolderChange(_acc.id, keep.id), isTrue);
      expect(await shownFolders(), contains('Keep'));
      expect(await db.select(db.pendingChanges).get(), isEmpty);

      await rig.mailboxes
          .moveMailbox(_acc.id, 'Keep', newParentDisplayPath: 'Archive');
      await flush();
      expect(server.folders.keys, contains('Archive/Keep'));
      expect(await rig.mailboxes.undoFolderChange(_acc.id, keep.id), isTrue);
      expect(await shownFolders(), contains('Keep'));
      await flush();
      expect(server.folders.keys, contains('Keep'));
      expect((await folder(keep.id)).path, 'Keep');
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);

      // A delete that was sent cannot be undone.
      await rig.mailboxes.deleteMailbox(_acc.id, 'Keep');
      await db.customStatement('UPDATE pending_changes SET attempts = 1');
      expect(await rig.mailboxes.undoFolderChange(_acc.id, keep.id), isFalse);
    });

    test(
        'a folder another client deleted while our delete is queued: the '
        'delete counts as done, nothing fails', () async {
      server.addFolder('Gone');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await rig.mailboxes.deleteMailbox(_acc.id, 'Gone');
      server.deleteFolder('Gone');

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(await _ops(db), [('delete_mailbox', 'acked')]);
      expect(events(), contains('mailbox.delete_found_done'));
      expect(events(), isNot(contains('pending_change.folder_removed')));
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await flush();
      expect(server.folderCommands, isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a subfolder deleted, then its parent: the flush deletes the '
        'subfolder first', () async {
      await addWork();
      await rig.mailboxes
          .deleteMailbox(_acc.id, 'Work/2026', removeEmails: true);
      await rig.mailboxes.deleteMailbox(_acc.id, 'Work');
      await flush();

      expect(server.folderCommands, ['DELETE Work/2026', 'DELETE Work']);
      expect(server.folders.keys, unorderedEquals(['INBOX', 'Archive']));
      await _expectConsistent(db);
    });

    test('a folder with subfolders that show is not deleted', () async {
      await addWork();
      await expectLater(
        rig.mailboxes.deleteMailbox(_acc.id, 'Work'),
        throwsA(predicate((e) => '$e'.contains('subfolders'))),
      );
      expect(await db.select(db.pendingChanges).get(), isEmpty);
    });

    test(
        'a move into a folder created offline waits for its create; a failed '
        'create fails the move and the folder shows where it was', () async {
      server.addFolder('Work');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await rig.mailboxes.createMailbox(_acc.id, 'Projects');
      await rig.mailboxes
          .moveMailbox(_acc.id, 'Work', newParentDisplayPath: 'Projects');
      expect(await shownFolders(), contains('Projects/Work'));

      await flush();
      expect(
        server.folderCommands,
        ['CREATE Projects', 'RENAME Work->Projects/Work'],
      );
      await _expectConsistent(db);

      server.refusesFolder = (path) => path == 'Bad';
      await rig.mailboxes.createMailbox(_acc.id, 'Bad');
      await rig.mailboxes.moveMailbox(
        _acc.id,
        'Projects/Work',
        newParentDisplayPath: 'Bad',
      );
      await flush();
      final ops = (await db.select(db.pendingChanges).get())
          .where((o) => o.state == 'failed')
          .map((o) => o.changeType);
      expect(ops, unorderedEquals(['create_mailbox', 'move_mailbox']));
      expect(await shownFolders(), contains('Projects/Work'));
      await _expectConsistent(db);
    });

    test(
        'a folder another client renamed (same UIDVALIDITY): its mail and '
        'the changes queued for it follow instead of failing', () async {
      server
        ..addFolder('Work')
        ..deliver('Work', 'w@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Work');
      final work = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Work');
      await emails.moveEmail((await rowOfA()).id, 'Work');
      server.renameFolder('Work', 'Job');

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect((await folder(work.id)).path, 'Job');
      expect((await mail('w@test')).srvMailboxPath, 'Job');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(move.state, 'pending');
      expect(move.payload, contains('"dest":"Job"'));
      expect(events(), contains('mailbox.renamed_elsewhere'));
      await flush();
      expect(server.find('a@test')!.folder.path, 'Job');
      await _expectConsistent(db);
    });

    test(
        'a folder another client renamed under a new UIDVALIDITY is '
        'recognised by its Message-IDs', () async {
      server
        ..addFolder('Work')
        ..deliver('Work', 'w@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Work');
      final work = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Work');
      await emails.moveEmail((await rowOfA()).id, 'Work');
      // Renamed, with a fresh UIDVALIDITY (as Stalwart does).
      final old = server.folders.remove('Work')!;
      server.addFolder('Job')
        ..messages.addAll(old.messages)
        ..uidNext = old.uidNext;

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect((await folder(work.id)).path, 'Job');
      expect((await mail('w@test')).srvMailboxPath, 'Job');
      final move = (await db.select(db.pendingChanges).get()).single;
      expect(
        (move.state, move.payload.contains('"dest":"Job"')),
        (
          'pending',
          true,
        ),
      );
      expect(
        logs.rows
            .singleWhere((r) => r.event == 'mailbox.renamed_elsewhere')
            .message,
        contains('Message-ID'),
      );
      await _expectConsistent(db);
    });

    // Review B1: a wrong match must never carry a queued op (least of all a
    // delete) to another folder.
    Future<void> workWithMail() async {
      server
        ..addFolder('Projects')
        ..deliver('Projects', 'p1@test')
        ..deliver('Projects', 'p2@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Projects');
    }

    FakeServerFolder copyOf(String from, String to, {int extra = 0}) {
      final copy = server.addFolder(to);
      for (final m in server.folders[from]!.messages.values) {
        server.deliver(to, m.messageId);
      }
      for (var i = 0; i < extra; i++) {
        server.deliver(to, 'extra$i@test');
      }
      return copy;
    }

    test(
        'a queued delete never follows a folder that looks renamed: the '
        'delete fails visibly naming it, the other folder stays (#1340)',
        () async {
      await workWithMail();
      await rig.mailboxes
          .deleteMailbox(_acc.id, 'Projects', removeEmails: true);
      // Webmail: copies the mail into a new sibling, adds none, deletes the
      // original. The match would be exact.
      copyOf('Projects', 'Projects-2026');
      server.deleteFolder('Projects');

      await rig.mailboxes.syncMailboxes(_acc.id);
      await flush();

      expect(server.folders.keys, contains('Projects-2026'));
      expect(server.folders['Projects-2026']!.messages, hasLength(2));
      expect(server.folderCommands, isEmpty);
      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      // Not counted as done: the folder may be the one there.
      expect(events(), contains('mailbox.delete_not_followed'));
      expect(await _ops(db), [('delete_mailbox', 'failed')]);
      final op = await db.select(db.pendingChanges).getSingle();
      expect(op.lastError, contains('renamed elsewhere to "Projects-2026"'));
      await _expectConsistent(db);
    });

    test(
        'a new folder holding the cached mail and more is no rename (a '
        'subset is not enough)', () async {
      await workWithMail();
      copyOf('Projects', 'Projects-2026', extra: 3);
      server.deleteFolder('Projects');

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.path),
        isNot(contains('Projects')),
      );
    });

    test('two new folders matching one gone folder: no rename (ambiguous)',
        () async {
      await workWithMail();
      copyOf('Projects', 'Projects-a');
      copyOf('Projects', 'Projects-b');
      server.deleteFolder('Projects');

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
    });

    test(
        'a new folder with the same count but other mail is no rename '
        '(Message-ID mismatch); nor one with the UIDVALIDITY but other mail',
        () async {
      await workWithMail();
      server
        ..addFolder('Projects-x')
        ..deliver('Projects-x', 'o1@test')
        ..deliver('Projects-x', 'o2@test');
      // The same UIDVALIDITY, other mail.
      final validity = server.folders['Projects']!.uidValidity;
      server.folders['Projects-y'] = FakeServerFolder('Projects-y', validity);
      server
        ..deliver('Projects-y', 'o3@test')
        ..deliver('Projects-y', 'o4@test')
        ..deleteFolder('Projects');

      await rig.mailboxes.syncMailboxes(_acc.id);

      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
    });

    test(
        "a folder's mail is out of reach while its delete is queued; a "
        'move out of it queued after the delete is sent first', () async {
      server
        ..addFolder('Old')
        ..deliver('Old', 'keep@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Old');
      final keep = await mail('keep@test');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Old', removeEmails: true);
      expect(await emails.getEmail(keep.id), isNull, reason: 'hidden');
      // Saved anyway (a screen opened before): it leaves the folder first.
      await emails.moveEmail(keep.id, 'INBOX');
      await flush();

      expect(server.find('keep@test')!.folder.path, 'INBOX');
      expect(server.folders.keys, isNot(contains('Old')));
      expect((await emails.getEmail(keep.id))!.mailboxPath, 'INBOX');
      await _expectConsistent(db);
    });

    test(
        "a delete waits while a counterpart's move out of the folder is not "
        'done (a shadow of a change not sent yet)', () async {
      server
        ..addFolder('Old')
        ..deliver('Old', 'tw@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Old');
      final twin = await mail('tw@test');
      // The primary, on another account, is not sent yet.
      final primary = await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _acc.id,
              resourceType: 'Email',
              resourceId: '${_acc.id}:elsewhere',
              changeType: 'flag_seen',
              payload: '{}',
              createdAt: DateTime(2026),
              state: const Value('parked'),
            ),
          );
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _acc.id,
              resourceType: 'Email',
              resourceId: twin.id,
              changeType: 'move',
              payload: '{"uid":1,"mailboxPath":"Old","dest":"INBOX"}',
              createdAt: DateTime(2026),
              state: const Value('shadow'),
              origin: Value('counterpart:$primary'),
            ),
          );
      await rig.mailboxes.deleteMailbox(_acc.id, 'Old', removeEmails: true);

      await flush();

      expect(server.folderCommands, isEmpty);
      expect(server.folders.keys, contains('Old'));
    });

    test(
        'with removeEmails, mail that arrived since the delete refuses it; '
        'Retry asks the server without deleting mail', () async {
      server
        ..addFolder('Busy')
        ..deliver('Busy', 'b1@test');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await rig.mailboxes.deleteMailbox(_acc.id, 'Busy', removeEmails: true);
      server.deliver('Busy', 'b2@test');

      await flush();

      final change = await db.select(db.pendingChanges).getSingle();
      expect((change.changeType, change.state), ('delete_mailbox', 'failed'));
      expect(change.lastError, contains('more mail'));
      expect(server.folders['Busy']!.messages, hasLength(2));
      expect(await shownFolders(), contains('Busy'));
      expect(events(), contains('mailbox.delete_new_mail'));

      await emails.retryMutation(change.id);
      final retried = await db.select(db.pendingChanges).getSingle();
      expect(retried.payload, '{"removeEmails":false}');
      await flush();
      expect(server.folders['Busy']!.messages, hasLength(2));
      await _expectConsistent(db);
    });

    test(
        'Undo of a sent move whose old parent is gone on the server: the '
        'move back is refused, the parent is not created again', () async {
      server
        ..addFolder('Box')
        ..addFolder('Box/Work');
      await rig.mailboxes.syncMailboxes(_acc.id);
      final work = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Box/Work');
      await rig.mailboxes
          .moveMailbox(_acc.id, 'Box/Work', newParentDisplayPath: null);
      await flush();
      expect(server.folders.keys, contains('Work'));
      server.deleteFolder('Box');

      expect(await rig.mailboxes.undoFolderChange(_acc.id, work.id), isTrue);
      await flush();
      // It waits for the listing first: another client may have renamed
      // or moved Box (#1329).
      expect(server.folders.keys, isNot(contains('Box')));
      expect(events(), contains('mailbox.op_waits_for_listing'));
      await rig.mailboxes.syncMailboxes(_acc.id);
      await flush();

      expect(server.folders.keys, isNot(contains('Box')));
      expect(server.folders.keys, contains('Work'));
      final failed = (await db.select(db.pendingChanges).get())
          .singleWhere((o) => o.state == 'failed');
      expect(
        failed.lastError,
        'the destination folder "Box" was removed on the server',
      );
    });

    test('Undo of a delete being sent says so and changes nothing', () async {
      server.addFolder('Sent2');
      await rig.mailboxes.syncMailboxes(_acc.id);
      final row = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.path == 'Sent2');
      await rig.mailboxes.deleteMailbox(_acc.id, 'Sent2');
      await db.customStatement(
        "UPDATE pending_changes SET state = 'inflight', claim_token = 'x'",
      );

      expect(await rig.mailboxes.undoFolderChange(_acc.id, row.id), isFalse);
      await pumpEventQueue();
      expect(
        logs.rows.singleWhere((r) => r.event == 'mailbox.undo').message,
        contains('being sent right now'),
      );
      expect((await folder(row.id)).localHidden, isTrue);
    });

    test(
        'a folder gone with another of a different UIDVALIDITY new: no '
        'match, the changes queued for it fail visibly', () async {
      server.addFolder('Work');
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Work');
      await emails.moveEmail((await rowOfA()).id, 'Work');
      server
        ..deleteFolder('Work')
        ..addFolder('Job');

      await rig.mailboxes.syncMailboxes(_acc.id);

      final move = (await db.select(db.pendingChanges).get()).single;
      expect(
        (move.state, move.lastError),
        ('failed', 'folder removed on the server'),
      );
      expect(events(), isNot(contains('mailbox.renamed_elsewhere')));
      await _expectConsistent(db);
    });

    test(
        'the Pending Changes list says which folder created offline a '
        'change waits for', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Projects');
      await emails.moveEmail((await rowOfA()).id, 'Projects');

      final listed = await emails.observePendingChanges(_acc.id).first;

      expect(
        listed.map((c) => (c.kind, c.waitingForFolder)),
        [('create_mailbox', null), ('move', 'Projects')],
      );
      await flush();
      expect(
        (await emails.observePendingChanges(_acc.id).first)
            .map((c) => c.waitingForFolder),
        everyElement(isNull),
      );
    });

    test(
        'the Pending Changes list names a folder created offline and renamed '
        'by its new name, and each folder change by its folder (#1335)',
        () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Projects');
      await emails.moveEmail((await rowOfA()).id, 'Projects');
      await rig.mailboxes.renameMailbox(_acc.id, 'Projects', 'Work');

      final listed = await emails.observePendingChanges(_acc.id).first;

      final move = listed.singleWhere((c) => c.kind == 'move');
      expect(move.waitingForFolder, 'Work');
      expect(move.folderNames['Projects'], 'Work');
      expect(move.folderName, isNull);
      expect(
        listed.singleWhere((c) => c.kind == 'create_mailbox').folderName,
        'Work',
      );
    });

    test(
        'the Pending Changes list names a subfolder created offline by its '
        'whole path, with its parent\'s new name (#1335)', () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      final projects = await rig.mailboxes.createMailbox(
        _acc.id,
        'Projects',
        parentDisplayPath: 'Old Mail',
      );
      await emails.moveEmail((await rowOfA()).id, projects.path);
      await rig.mailboxes.renameMailbox(_acc.id, projects.path, 'Work');

      final listed = await emails.observePendingChanges(_acc.id).first;

      final move = listed.singleWhere((c) => c.kind == 'move');
      expect(move.folderNames[projects.path], 'Old Mail/Work');
      expect(move.waitingForFolder, 'Old Mail/Work');
      expect(
        listed.singleWhere((c) => c.kind == 'create_mailbox').folderName,
        'Old Mail/Work',
      );
    });

    test(
        'the Pending Changes list names a server folder renamed offline by '
        'its new name while the server still has the old one (#1335)',
        () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      // The folder keeps the server's path until the rename is confirmed.
      final archive = (await db.select(db.mailboxes).get())
          .singleWhere((m) => m.displayPath == 'Old Mail');
      expect(archive.path, 'Archive');
      await emails.moveEmail((await rowOfA()).id, archive.path);

      final listed = await emails.observePendingChanges(_acc.id).first;

      final move = listed.singleWhere((c) => c.kind == 'move');
      expect(move.folderNames['Archive'], 'Old Mail');
      expect(move.waitingForFolder, isNull);
      expect(
        listed.singleWhere((c) => c.kind == 'rename_mailbox').folderName,
        'Old Mail',
      );
    });

    test(
        'a snooze without a Snoozed folder queues its create; the flush '
        'creates it before the snooze, never on the side', () async {
      await emails.snoozeEmail(
        (await rowOfA()).id,
        DateTime.utc(2026, 12),
      );
      expect(await _ops(db), [
        ('create_mailbox', 'pending'),
        ('snooze', 'pending'),
      ]);

      await flush();

      expect(server.folderCommands, ['CREATE Snoozed']);
      expect(server.find('a@test')!.folder.path, 'Snoozed');
      await _expectConsistent(db);
    });
  });

  group('JMAP', () {
    final cacheDir = useJmapTestEnv('mailbox_ops_');
    const jmapAccount = Account(
      id: 'jmap-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://jmap.example.com/.well-known/jmap',
    );

    late _JmapFolders server;
    late JmapTestRepos r;
    late MailboxRepositoryImpl mailboxes;

    setUp(() async {
      server = _JmapFolders();
      r = await openJmapTestRepos(
        httpClient: server.client,
        account: jmapAccount,
        cacheDir: cacheDir(),
      );
      mailboxes = MailboxRepositoryImpl(
        r.db,
        r.accounts,
        httpClient: server.client,
      );
      await mailboxes.syncMailboxes(jmapAccount.id);
      await insertJmapEmailRow(
        r.db,
        jmapAccount.id,
        'e1',
        mailboxPath: 'inbox',
      );
    });
    tearDown(() => r.db.close());

    Future<void> flush() => r.emails.flushPendingChanges(jmapAccount.id, 'pw');
    Future<Email> e1() => (r.db.select(r.db.emails)
          ..where((t) => t.id.equals('${jmapAccount.id}:e1')))
        .getSingle();

    test(
        'offline create, move into it, flush: the folder gets its server id, '
        'the move names it and lands there', () async {
      final folder = await mailboxes.createMailbox(jmapAccount.id, 'Projects');
      expect(folder.path, startsWith(localJmapMailboxPrefix));
      await r.emails.moveEmail('${jmapAccount.id}:e1', folder.path);
      expect((await e1()).mailboxPath, folder.path);

      // Offline: nothing is sent.
      server.offline = true;
      await flush();
      expect(server.created, isEmpty);
      server.offline = false;

      await flush();

      final id = server.created.single;
      expect(server.moves, {'e1': id});
      final row = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.id.equals(folder.id)))
          .getSingle();
      expect((row.path, row.name, row.isLocal), (id, 'Projects', false));
      final e = await e1();
      expect((e.mailboxPath, e.srvMailboxPath), (id, id));
      await _expectConsistent(r.db);

      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(
        (await _ops(r.db)).where((o) => o.$1 == 'create_mailbox'),
        isEmpty,
      );
      await _expectConsistent(r.db);
    });

    test(
        'a refused create fails the move waiting for it; the mail shows in '
        'its folder again', () async {
      server.refuseCreate = true;
      final folder = await mailboxes.createMailbox(jmapAccount.id, 'Bad');
      await r.emails.moveEmail('${jmapAccount.id}:e1', folder.path);

      await flush();

      expect(await _ops(r.db), [
        ('create_mailbox', 'failed'),
        ('move', 'failed'),
      ]);
      expect(server.moves, isEmpty);
      expect((await e1()).mailboxPath, 'inbox');
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.name), isNot(contains('Bad')));
      await _expectConsistent(r.db);
    });

    test(
        'a create whose answer was lost finds the folder (no second '
        'create) and the next listing settles it although Mailbox/changes '
        'does not name it', () async {
      await mailboxes.createMailbox(jmapAccount.id, 'Lost');
      // The create reached the server, its answer did not.
      server.addElsewhere('mbx-lost', 'Lost');
      await r.db.customStatement(
        'UPDATE pending_changes SET attempts = 1 WHERE change_type = '
        "'create_mailbox'",
      );
      // A listing in between: the folder is the server's, not a second one.
      await mailboxes.syncMailboxes(jmapAccount.id);

      await flush();

      expect(server.created, isEmpty);
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.where((m) => m.name == 'Lost'), hasLength(1));
      expect(shown.singleWhere((m) => m.name == 'Lost').path, 'mbx-lost');
      expect(await _ops(r.db), [('create_mailbox', 'acked')]);

      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(await _ops(r.db), isEmpty);
      await _expectConsistent(r.db);
    });

    test(
        "a move queued from a screen that still names the folder's stand-in "
        "goes to the server's id; an unknown stand-in fails", () async {
      final folder = await mailboxes.createMailbox(jmapAccount.id, 'P');
      await flush();
      final id = server.created.single;

      await r.emails.moveEmail('${jmapAccount.id}:e1', folder.path);
      final move = (await r.db.select(r.db.pendingChanges).get()).last;
      expect(move.payload, contains('"dest":"$id"'));

      await insertJmapEmailRow(
        r.db,
        jmapAccount.id,
        'e2',
        mailboxPath: 'inbox',
      );
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: jmapAccount.id,
              resourceType: 'Email',
              resourceId: '${jmapAccount.id}:e2',
              changeType: 'move',
              payload: '{"dest":"~new:gone","jmapId":"e2"}',
              createdAt: DateTime(2026),
            ),
          );
      await flush();
      expect(server.moves, {'e1': id});
      final gone = (await r.db.select(r.db.pendingChanges).get())
          .singleWhere((o) => o.resourceId == '${jmapAccount.id}:e2');
      expect(gone.state, 'failed');
      expect(gone.lastError, contains('never created'));
    });

    test(
        'offline rename shows at once; the flush sends it; the next listing '
        'confirms it', () async {
      final renamed =
          await mailboxes.renameMailbox(jmapAccount.id, 'archive', 'Old');
      expect(renamed.name, 'Old');
      expect(server.mailboxes['archive']!['name'], 'Archive');

      await flush();
      expect(server.mailboxes['archive']!['name'], 'Old');
      expect(await _ops(r.db), [('rename_mailbox', 'acked')]);

      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(await _ops(r.db), isEmpty);
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.singleWhere((m) => m.path == 'archive').name, 'Old');
      await _expectConsistent(r.db);
    });

    test(
        'offline move shows the folder below its new parent; the flush sets '
        'parentId; the next listing settles it', () async {
      server.addElsewhere('work', 'Work');
      await mailboxes.syncMailboxes(jmapAccount.id);

      final moved = await mailboxes.moveMailbox(
        jmapAccount.id,
        'work',
        newParentDisplayPath: 'Archive',
      );
      expect((moved.parentId, moved.displayPath), ('archive', 'Archive/Work'));
      server.offline = true;
      await flush();
      expect(server.mailboxes['work']!['parentId'], isNull);
      server.offline = false;

      await flush();

      expect(server.mailboxes['work']!['parentId'], 'archive');
      expect(await _ops(r.db), [('move_mailbox', 'acked')]);
      await _expectConsistent(r.db);
      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(await _ops(r.db), isEmpty);
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(
        shown.singleWhere((m) => m.path == 'work').displayPath,
        'Archive/Work',
      );
      await _expectConsistent(r.db);
    });

    test(
        'a move into a folder created offline waits for it and names its '
        'server id', () async {
      server.addElsewhere('work', 'Work');
      await mailboxes.syncMailboxes(jmapAccount.id);
      final projects =
          await mailboxes.createMailbox(jmapAccount.id, 'Projects');
      await mailboxes.moveMailbox(
        jmapAccount.id,
        'work',
        newParentDisplayPath: 'Projects',
      );

      await flush();

      final id = server.created.single;
      expect(server.mailboxes['work']!['parentId'], id);
      final row = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.id.equals(projects.id)))
          .getSingle();
      expect(row.path, id);
      await _expectConsistent(r.db);
    });

    test(
        'offline delete hides the folder; the flush destroys it with its '
        'mail when the user said so; a stale full listing does not bring '
        'it back', () async {
      server.addElsewhere('old', 'Old');
      await mailboxes.syncMailboxes(jmapAccount.id);
      await insertJmapEmailRow(r.db, jmapAccount.id, 'e2', mailboxPath: 'old');

      await mailboxes.deleteMailbox(
        jmapAccount.id,
        'old',
        removeEmails: true,
      );
      var shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.path), isNot(contains('old')));

      await flush();

      expect(server.destroyed, ['old']);
      expect(server.destroyRemovedEmails, [true]);
      expect(
        (await r.db.select(r.db.mailboxes).get()).map((m) => m.path),
        isNot(contains('old')),
      );
      expect(await _ops(r.db), [('delete_mailbox', 'acked')]);

      // A full listing whose answer predates the destroy (its read
      // sequence is older than the ack's) still lists the folder.
      server.mailboxes['old'] = {'id': 'old', 'name': 'Old'};
      await r.db.customStatement(
        "DELETE FROM sync_states WHERE resource_type = 'Mailbox'",
      );
      final later = await EmailStateWriter(r.db).nextReadSeq() + 5;
      await r.db.customStatement(
        'UPDATE pending_changes SET ack_seq = $later '
        "WHERE change_type = 'delete_mailbox'",
      );
      await mailboxes.syncMailboxes(jmapAccount.id);
      shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.path), isNot(contains('old')));
      expect(await _ops(r.db), [('delete_mailbox', 'acked')]);
      server.mailboxes.remove('old');
      await _expectConsistent(r.db);
    });

    test(
        'a delete the server refuses (mail in it, not confirmed) fails, the '
        'folder shows again; Retry hides it again', () async {
      server.addElsewhere('full', 'Full');
      server.hasEmail.add('full');
      await mailboxes.syncMailboxes(jmapAccount.id);

      await mailboxes.deleteMailbox(jmapAccount.id, 'full');
      await flush();

      final change = await r.db.select(r.db.pendingChanges).getSingle();
      expect((change.changeType, change.state), ('delete_mailbox', 'failed'));
      expect(change.lastError, contains('mailboxHasEmail'));
      var shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.path), contains('full'));
      await _expectConsistent(r.db);

      await r.emails.retryMutation(change.id);
      shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.path), isNot(contains('full')));
      await _expectConsistent(r.db);
    });
  });
}

/// A JMAP server with a few mailboxes that creates and renames them and
/// moves mail ([moves]: email id → mailbox id).
class _JmapFolders {
  _JmapFolders() {
    client = jmapFakeServer(accountId: 'u1', handle: _handle, handleRaw: _raw);
  }

  late final http.Client client;
  bool offline = false;

  /// Another client creates a mailbox [id] called [name].
  void addElsewhere(String id, String name) {
    _state++;
    mailboxes[id] = {'id': id, 'name': name};
    _changes.add((_state, id, true));
  }

  bool refuseCreate = false;

  /// Mailboxes that have mail: a destroy without `onDestroyRemoveEmails`
  /// is refused (`mailboxHasEmail`).
  final Set<String> hasEmail = {};

  /// The mailboxes destroyed, and each destroy's `onDestroyRemoveEmails`.
  final List<String> destroyed = [];
  final List<bool> destroyRemovedEmails = [];
  final Map<String, Map<String, dynamic>> mailboxes = {
    'inbox': {'id': 'inbox', 'name': 'Inbox', 'role': 'inbox'},
    'archive': {'id': 'archive', 'name': 'Archive', 'role': 'archive'},
  };
  final List<String> created = [];
  final Map<String, String> moves = {};
  var _state = 1;

  /// What each state change did: (state after, mailbox id, created?).
  final List<(int, String, bool)> _changes = [];

  /// The mailboxes destroyed: (state after, mailbox id).
  final List<(int, String)> _destroyedAt = [];

  http.Response? _raw(http.BaseRequest request) {
    if (offline) throw const SocketException('offline');
    return null;
  }

  List<dynamic>? _handle(JmapCall call) {
    switch (call.method) {
      case 'Mailbox/get':
        return [
          'Mailbox/get',
          {
            'accountId': 'u1',
            'state': 'm$_state',
            'list': [
              for (final m in mailboxes.values)
                {
                  ...m,
                  'parentId': m['parentId'],
                  'totalEmails': 0,
                  'unreadEmails': 0,
                },
            ],
          },
          call.callId,
        ];
      case 'Mailbox/changes':
        // Only what changed since the state asked about, as a server does.
        final since =
            int.parse((call.args['sinceState'] as String).substring(1));
        final changed = [
          for (final c in _changes)
            if (c.$1 > since) c,
        ];
        return [
          'Mailbox/changes',
          {
            'accountId': 'u1',
            'oldState': call.args['sinceState'],
            'newState': 'm$_state',
            'hasMoreChanges': false,
            'created': [
              for (final c in changed)
                if (c.$3) c.$2,
            ],
            'updated': {
              for (final c in changed)
                if (!c.$3) c.$2,
            }.toList(),
            'destroyed': [
              for (final (state, id) in _destroyedAt)
                if (state > since) id,
            ],
          },
          call.callId,
        ];
      case 'Mailbox/set':
        final result = <String, dynamic>{'accountId': 'u1'};
        final notCreated = <String, dynamic>{};
        final createdIds = <String, dynamic>{};
        final updated = <String, dynamic>{};
        final create = call.args['create'] as Map<String, dynamic>?;
        if (create != null) {
          for (final MapEntry(:key, :value) in create.entries) {
            if (refuseCreate) {
              notCreated[key] = {'type': 'invalidProperties'};
              continue;
            }
            final id = 'mbx-${created.length + 1}';
            created.add(id);
            _changes.add((_state + 1, id, true));
            mailboxes[id] = {
              'id': id,
              ...(value as Map<String, dynamic>),
            };
            createdIds[key] = {'id': id};
          }
        }
        final update = call.args['update'] as Map<String, dynamic>?;
        if (update != null) {
          for (final MapEntry(:key, :value) in update.entries) {
            mailboxes[key]!.addAll(value as Map<String, dynamic>);
            _changes.add((_state + 1, key, false));
            updated[key] = null;
          }
        }
        final destroy = call.args['destroy'] as List<dynamic>?;
        final notDestroyed = <String, dynamic>{};
        final destroyedIds = <String>[];
        for (final id in destroy ?? const []) {
          final removeEmails = call.args['onDestroyRemoveEmails'] == true;
          if (!mailboxes.containsKey(id)) {
            notDestroyed[id as String] = {'type': 'notFound'};
            continue;
          }
          if (hasEmail.contains(id) && !removeEmails) {
            notDestroyed[id as String] = {'type': 'mailboxHasEmail'};
            continue;
          }
          mailboxes.remove(id);
          destroyed.add(id as String);
          destroyRemovedEmails.add(removeEmails);
          _destroyedAt.add((_state + 1, id));
          destroyedIds.add(id);
        }
        if (notDestroyed.isNotEmpty) result['notDestroyed'] = notDestroyed;
        if (destroyedIds.isNotEmpty) result['destroyed'] = destroyedIds;
        if (notCreated.isNotEmpty) result['notCreated'] = notCreated;
        if (createdIds.isNotEmpty) result['created'] = createdIds;
        if (updated.isNotEmpty) result['updated'] = updated;
        _state++;
        return ['Mailbox/set', result, call.callId];
      case 'Email/set':
        final update = call.args['update'] as Map<String, dynamic>;
        for (final MapEntry(:key, :value) in update.entries) {
          final ids = (value as Map<String, dynamic>)['mailboxIds'];
          if (ids is Map) moves[key] = ids.keys.single as String;
        }
        return [
          'Email/set',
          {
            'accountId': 'u1',
            'updated': {for (final id in update.keys) id: null},
          },
          call.callId,
        ];
    }
    return null;
  }
}
