// Another client moves a mail from INBOX to Archive, and this device syncs
// INBOX first (#1313). The absence rule finds the mail gone; with a
// Message-ID its row waits, hidden, until another folder's sync stores the
// mail: that sync adopts it, and the row keeps its id, body, attachments and
// references. When no folder receives it (a delete elsewhere), the wait ends
// once a folder listing and every other folder synced since, or after
// EmailStateWriter.foreignMoveMaxWait, and the clean-up rule removes it.
// The other order (destination first) without EMAILID is matched by
// Message-ID when the source's sync finds the mail gone.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  Future<void> open({
    bool objectIds = false,
    List<(String, String)> extra = const [],
  }) async {
    logs = await openRigWithMailA(
      uidValidityByFolder: {
        'INBOX': 11,
        'Archive': 22,
        'Spam': 33,
        for (final (path, _) in extra) path: 40 + extra.length,
      },
      folders: [
        ('INBOX', 'inbox'),
        ('Archive', 'archive'),
        ('Spam', 'junk'),
        ...extra,
      ],
      objectIds: objectIds,
    );
  }

  tearDown(() => db.close());

  Future<void> sync(String folder) => emails.syncEmails(_account.id, folder);

  const addBody = rigAddBody;
  const bodyOf = rigBodyOf;

  Iterable<AppLogEntry> logsOf(String event) =>
      logs.rows.where((l) => l.event == event);

  /// INBOX (where a@test vanished), a listing and the other folders
  /// synced: the wait ends, the row is removed; the expiry's App Log line.
  Future<AppLogEntry> syncUntilExpired() async {
    await sync('INBOX');
    await rigListFolders();
    await sync('Archive');
    await sync('Spam');
    expect(await rowsOfA(), isEmpty);
    return logsOf('email.foreign_move_wait_expired').single;
  }

  Future<Email> rowOfA2(String id) async =>
      (await rowsOfA()).singleWhere((e) => e.id == id);

  Map<String, dynamic> dataOf(AppLogEntry entry) =>
      jsonDecode(entry.dataJson!) as Map<String, dynamic>;

  Future<void> setRow(String id, EmailsCompanion values) =>
      (db.update(db.emails)..where((t) => t.id.equals(id))).write(values);

  Future<String?> syncState(String key) async => (await (db.select(
        db.syncStates,
      )..where((t) => t.resourceType.equals(key)))
              .getSingleOrNull())
          ?.state;

  group('source synced first', () {
    setUp(open);

    test('the destination adopts the row: same id, body and attachments',
        () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      await db.into(db.attachmentFiles).insert(
            AttachmentFilesCompanion.insert(
              emailId: id,
              filename: 'a.pdf',
              size: 3,
              downloadedAt: now,
            ),
          );
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');

      // Gone from INBOX, waiting: hidden, but kept with its body.
      var e = await rowOfA();
      expect(e.id, id);
      expect((e.srvGone, e.mailboxPath), (true, ''));
      expect(e.foreignMoveWaitSeq, isNotNull);
      expect(e.foreignMoveWaitSince, isNotNull);
      expect(await bodyOf(id), 'cached body');

      await sync('Archive');

      e = await rowOfA();
      expect(e.id, id);
      expect(e.mailboxPath, 'Archive');
      expect(
        (e.srvMailboxPath, e.srvUid, e.srvUidValidity),
        ('Archive', 2, 22),
      );
      expect(e.srvGone, isFalse);
      expect((e.foreignMoveWaitSeq, e.foreignMoveWaitSince), (null, null));
      expect(await bodyOf(id), 'cached body');
      final files = await db.select(db.attachmentFiles).get();
      expect(files.map((f) => f.emailId), [id]);
      final adopted = logsOf('email.foreign_move_adopted').single;
      expect(adopted.emailId, id);
      expect(adopted.mailboxPath, 'Archive');
      final data = jsonDecode(adopted.dataJson!) as Map<String, dynamic>;
      expect((data['from'], data['to']), ('INBOX', 'Archive'));
      expect(data['droppedEmailId'], isNot(id));
      // The thread lists follow.
      final threads = await db.select(db.threads).get();
      expect(threads.where((t) => t.mailboxPath == 'INBOX'), isEmpty);
      expect(
        threads.where(
          (t) => t.mailboxPath == 'Archive' && t.latestEmailId == id,
        ),
        hasLength(1),
      );
      expect(await rigProblems(), isEmpty);
      // Synced again: nothing changes.
      await sync('INBOX');
      await sync('Archive');
      expect((await rowOfA()).id, id);
      expect(await rowsOfA(), hasLength(1));
    });

    test('a waiting row shows nowhere', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      // A queued read change: the unread delta must not count the row.
      await emails.setFlag(id, seen: true);
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');
      await rigListFolders();
      final counts = {
        for (final m in await rig.mailboxes.observeMailboxes(_account.id).first)
          m.path: m.unreadCount,
      };
      // The server's counts (a@test is unread in Archive there) and no
      // delta from the hidden row.
      expect(counts, {'INBOX': 0, 'Archive': 2, 'Spam': 0});

      expect(await emails.getEmail(id), isNull);
      expect(await emails.observeEmails(_account.id, 'INBOX').first, isEmpty);
      expect(await emails.observeThreads(_account.id, 'INBOX').first, isEmpty);
      expect(
        await emails.searchEmailsGlobal(_account.id, 'Mail a@test'),
        isEmpty,
      );
      expect(
        await emails.searchEmails(_account.id, 'INBOX', 'cached'),
        isEmpty,
      );
      // Prefetch, notifications and counts skip a row shown nowhere.
      expect((await rowOfA()).mailboxPath, '');
    });

    test('a restart between the two syncs still adopts the row', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      server.moveElsewhere('a@test', 'Archive');
      await sync('INBOX');

      // A new repository on the same database: the app restarted, or the
      // background isolate syncs the destination.
      final restarted = EmailRepositoryImpl(
        db,
        rig.accounts,
        imapConnect: (_, __, ___) async => server.connect(),
        smtpConnect: (_, __, ___) =>
            Future.error(UnsupportedError('no SMTP in this test')),
        fetchPreviewSnippets: (_, __, ___) async => const {},
        now: () => rig.now,
        appLogger: AppLogger(logs),
      );
      await restarted.syncEmails(_account.id, 'Archive');

      final e = await rowOfA();
      expect((e.id, e.mailboxPath, e.srvGone), (id, 'Archive', false));
      expect(await bodyOf(id), 'cached body');
    });

    test('a change queued before the move follows the mail and is sent',
        () async {
      final id = (await rowOfA()).id;
      await emails.setFlag(id, flagged: true);
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');
      // Kept for the change and waiting, hidden: no move shows it.
      var e = await rowOfA();
      expect((e.srvGone, e.foreignMoveWaitSeq != null), (true, true));
      // A flush now holds the change: sent to the vanished UID, the STORE
      // would answer OK and do nothing.
      await emails.flushPendingChanges(_account.id, 'pw');
      expect(server.find('a@test')!.message.flagged, isFalse);
      expect((await rigOps()).single.state, 'pending');

      await sync('Archive');

      e = await rowOfA();
      expect((e.id, e.mailboxPath, e.isFlagged), (id, 'Archive', true));
      final change = (await rigOps()).single;
      expect(change.resourceId, id);
      final payload = jsonDecode(change.payload) as Map<String, dynamic>;
      expect(
        (payload['mailboxPath'], payload['uid'], payload['uidValidity']),
        ('Archive', 2, 22),
      );

      await emails.flushPendingChanges(_account.id, 'pw');

      expect(server.find('a@test')!.message.flagged, isTrue);
      expect(server.find('a@test')!.folder.path, 'Archive');
      expect(await unsettledChanges(db), isEmpty);
      expect(await rigProblems(), isEmpty);
    });

    test('a row with a queued move of its own is not adopted', () async {
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Spam');
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');
      // Its own move explains the absence: no wait, the ops path settles it.
      expect((await rowOfA()).foreignMoveWaitSeq, isNull);
      await sync('Archive');

      // The user's move shows the row in Spam; the copy in Archive is a row
      // of its own: which place the user wants is the move's to settle.
      final rows = await rowsOfA();
      expect(rows.map((e) => e.id), contains(id));
      expect(rows, hasLength(2));
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });

    test('with EMAILID (OBJECTID) the adoption works the same', () async {
      await db.close();
      await open(objectIds: true);
      final id = (await rowOfA()).id;
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');
      await sync('Archive');

      final e = await rowOfA();
      expect(
        (e.id, e.mailboxPath, e.serverEmailId),
        (id, 'Archive', 'E-a@test'),
      );
      expect(logsOf('email.foreign_move_adopted'), hasLength(1));
    });

    test('a mail without a Message-ID is removed at once, as before', () async {
      server.deliver('INBOX', '${noMessageIdPrefix}x');
      await sync('INBOX');
      final before = await db.select(db.emails).get();
      final noId = before.singleWhere((e) => e.messageId == null);
      server.expungeElsewhere('${noMessageIdPrefix}x');

      await sync('INBOX');

      final row = await (db.select(db.emails)
            ..where((t) => t.id.equals(noId.id)))
          .getSingleOrNull();
      expect(row, isNull);
    });
  });

  group('the wait ends', () {
    setUp(open);

    test('once every other folder synced since: the row is removed', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      server.expungeElsewhere('a@test');

      await sync('INBOX');
      expect((await rowOfA()).foreignMoveWaitSeq, isNotNull);
      await rigListFolders();
      // Archive synced since, Spam not yet: Spam may still get it.
      await sync('Archive');
      expect(await rowsOfA(), hasLength(1));
      // INBOX itself does not count.
      await sync('INBOX');
      expect(await rowsOfA(), hasLength(1));

      await sync('Spam');

      expect(await rowsOfA(), isEmpty);
      expect(await bodyOf(id), isNull);
      final expired = logsOf('email.foreign_move_wait_expired').single;
      expect(expired.level, AppLogLevel.warn);
      final data = jsonDecode(expired.dataJson!) as Map<String, dynamic>;
      expect(
        (data['removedEmailId'], data['from'], data['body'], data['reason']),
        (id, 'INBOX', true, 'folders_synced'),
      );
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });

    test('not before a folder listing that started after the mark', () async {
      server.expungeElsewhere('a@test');
      await rigListFolders();

      await sync('INBOX');
      await sync('Archive');
      await sync('Spam');
      expect(await rowsOfA(), hasLength(1), reason: 'no listing since');

      await rigListFolders();
      await sync('Archive');
      expect(await rowsOfA(), isEmpty);
    });

    test('a move into a folder made meanwhile waits for its sync', () async {
      final id = (await rowOfA()).id;
      server
        ..addFolder('New')
        ..moveElsewhere('a@test', 'New');

      await sync('INBOX');
      await sync('Archive');
      await sync('Spam');
      expect((await rowOfA()).srvGone, isTrue, reason: 'New is not listed');
      await rigListFolders();
      await sync('Archive');
      await sync('Spam');
      expect((await rowOfA()).srvGone, isTrue, reason: 'New not synced yet');

      await sync('New');

      final e = await rowOfA();
      expect((e.id, e.mailboxPath, e.srvGone), (id, 'New', false));
    });

    test('without a cached body the expiry is logged as info', () async {
      server.expungeElsewhere('a@test');

      final expired = await syncUntilExpired();

      expect(expired.level, AppLogLevel.info);
    });

    test('after foreignMoveMaxWait even if a folder never synced', () async {
      server.expungeElsewhere('a@test');
      await sync('INBOX');
      // Re-marked gone by a later sync of INBOX: the wait keeps its start.
      now = now.add(const Duration(hours: 1));
      await sync('INBOX');
      expect(await rowsOfA(), hasLength(1));

      now = now.add(
        EmailStateWriter.foreignMoveMaxWait - const Duration(minutes: 30),
      );
      await sync('INBOX');

      expect(await rowsOfA(), isEmpty);
      final expired = logsOf('email.foreign_move_wait_expired').single;
      expect(dataOf(expired)['reason'], 'max_wait');
    });

    test('a wait that ended is not started again', () async {
      final id = (await rowOfA()).id;
      // Kept after its wait for this change.
      await emails.setFlag(id, flagged: true);
      server.expungeElsewhere('a@test');
      await sync('INBOX');
      await rigListFolders();
      await sync('Archive');
      await sync('Spam');
      var e = await rowOfA();
      expect((e.srvGone, e.foreignMoveWaitSeq), (true, null));

      await sync('INBOX');

      e = await rowOfA();
      expect(e.foreignMoveWaitSeq, isNull);
    });

    test('a sync that started before the mark does not end the wait', () async {
      // Another isolate's Archive and Spam syncs started after INBOX's
      // search was sent, and searched before the move: their markers hold
      // later sequences than that search.
      final writer = EmailStateWriter(db);
      final id = (await rowOfA()).id;
      final search = await writer.beginRead(_account.id);
      server.expungeElsewhere('a@test');
      final otherStart = await writer.nextReadSeq();
      for (final key in [
        '${EmailStateWriter.folderSyncedPrefix}Archive',
        '${EmailStateWriter.folderSyncedPrefix}Spam',
        EmailStateWriter.folderListedKey,
      ]) {
        await db.into(db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: _account.id,
                resourceType: key,
                state: '$otherStart',
                syncedAt: now,
              ),
            );
      }

      await search.markGone([id], awaitForeignMove: true);

      expect((await rowOfA()).foreignMoveWaitSeq, greaterThan(otherStart));
      expect(await writer.expireForeignMoveWaits(_account.id), isEmpty);
    });

    test('a sync that fetched nothing does not count as synced', () async {
      const key = '${EmailStateWriter.folderSyncedPrefix}Archive';
      final before = await syncState(key);
      expect(before, isNotNull);
      // A UIDVALIDITY change whose re-match is deferred: SEARCH ALL
      // answers nothing while SELECT counts mail.
      server
        ..renumberFolder('Archive', 99)
        ..searchAllEmpty = true;

      await sync('Archive');

      expect(await syncState(key), before);
    });

    test('a mail that arrives after the wait ended gets a new row', () async {
      final id = (await rowOfA()).id;
      server.expungeElsewhere('a@test');
      await sync('INBOX');
      await rigListFolders();
      await sync('Archive');
      await sync('Spam');
      expect(await rowsOfA(), isEmpty);

      server.deliver('Archive', 'a@test');
      await sync('Archive');

      final e = await rowOfA();
      expect(e.id, isNot(id));
      expect(e.mailboxPath, 'Archive');
    });
  });

  group('no adoption without a unique match', () {
    setUp(open);

    test('two waiting rows with the Message-ID: the arrival is a new row',
        () async {
      // A second copy of a@test in Spam; both vanish.
      server.deliver('Spam', 'a@test');
      await sync('Spam');
      // INBOX lists its copy again after the Spam copy was stored: two
      // copies, not a move.
      await sync('INBOX');
      final ids = (await rowsOfA()).map((e) => e.id).toSet();
      expect(ids, hasLength(2));
      server.moveElsewhere('a@test', 'Archive'); // the INBOX copy
      final spam = server.folders['Spam']!;
      spam.messages.removeWhere((_, m) => m.messageId == 'a@test');

      await sync('INBOX');
      await sync('Spam');
      await sync('Archive');

      final rows = await rowsOfA();
      final shown = rows.where((e) => e.mailboxPath.isNotEmpty).toList();
      expect(shown.map((e) => e.mailboxPath), ['Archive']);
      expect(ids, isNot(contains(shown.single.id)));
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
      expect(await rigProblems(), isEmpty);
    });

    test('two copies arrive in one folder: neither adopts the row', () async {
      final id = (await rowOfA()).id;
      server
        ..moveElsewhere('a@test', 'Archive')
        ..deliver('Archive', 'a@test');

      await sync('INBOX');
      await sync('Archive');

      final shown =
          (await rowsOfA()).where((e) => e.mailboxPath == 'Archive').toList();
      expect(shown, hasLength(2));
      expect(shown.map((e) => e.id), isNot(contains(id)));
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });
  });

  group('a second copy of a self-sent mail', () {
    setUp(() => open(extra: [('Sent', 'sent')]));

    test('the Sent copy arriving later does not adopt the Inbox row', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'inbox body');
      server
        ..deliver('Sent', 'a@test')
        // The Inbox copy is deleted elsewhere (found first: INBOX).
        ..expungeElsewhere('a@test');

      await sync('INBOX');
      await sync('Sent');

      final sent =
          (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Sent');
      expect(sent.id, isNot(id));
      expect(await bodyOf(sent.id), isNull);
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });

    test('the live Sent copy is left alone when the Inbox copy moves',
        () async {
      final id = (await rowOfA()).id;
      server.deliver('Sent', 'a@test');
      await sync('Sent');
      final sentId =
          (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Sent').id;
      server.moveElsewhere('a@test', 'Archive'); // the INBOX copy

      await sync('INBOX');
      await sync('Archive');

      final rows = {for (final e in await rowsOfA()) e.id: e.mailboxPath};
      expect(rows, {id: 'Archive', sentId: 'Sent'});
      expect(logsOf('email.foreign_move_adopted'), hasLength(1));
    });
  });

  group('Gmail All Mail', () {
    setUp(() => open(extra: [('[Gmail]/All Mail', 'all')]));

    test('a mail fetched in All Mail does not adopt a waiting row', () async {
      final id = (await rowOfA()).id;
      server.moveElsewhere('a@test', '[Gmail]/All Mail'); // archived

      await sync('INBOX');
      // An explicit sync of All Mail (the sync loops skip it).
      await sync('[Gmail]/All Mail');

      final rows = await rowsOfA();
      final shown = rows.singleWhere((e) => e.mailboxPath.isNotEmpty);
      expect(shown.mailboxPath, '[Gmail]/All Mail');
      expect(shown.id, isNot(id));
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
      expect(rows.map((e) => e.id), contains(id));
      // All Mail is no folder the wait waits for.
      await rigListFolders();
      await sync('Archive');
      await sync('Spam');
      expect((await rowsOfA()).map((e) => e.id), isNot(contains(id)));
    });

    test('archived elsewhere (only in All Mail): the expiry is info', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      server.moveElsewhere('a@test', '[Gmail]/All Mail');

      final expired = await syncUntilExpired();

      expect(expired.level, AppLogLevel.info);
      expect(dataOf(expired)['body'], isTrue);
    });

    test('a mail gone from All Mail does not wait', () async {
      server.deliver('[Gmail]/All Mail', 'b@test');
      await sync('[Gmail]/All Mail');
      server.expungeElsewhere('b@test');

      await sync('[Gmail]/All Mail');

      final rows = await (db.select(db.emails)
            ..where((t) => t.messageId.equals('b@test')))
          .get();
      expect(rows, isEmpty);
    });
  });

  group('destination synced first, no EMAILID', () {
    setUp(open);

    test('the source sync matches the new row by Message-ID', () async {
      final id = (await rowOfA()).id;
      await addBody(id, 'cached body');
      server.moveElsewhere('a@test', 'Archive');

      await sync('Archive');
      expect(await rowsOfA(), hasLength(2), reason: 'a new row in Archive');
      await sync('INBOX');

      final e = await rowOfA();
      expect((e.id, e.mailboxPath, e.srvGone), (id, 'Archive', false));
      expect(
        (e.srvMailboxPath, e.srvUid, e.srvUidValidity),
        ('Archive', 2, 22),
      );
      expect(await bodyOf(id), 'cached body');
      final adopted = logsOf('email.foreign_move_adopted').single;
      expect(dataOf(adopted)['order'], 'destination_first');
      expect(await rigProblems(), isEmpty);
    });

    test('a copy stored before the source last listed the mail is no match',
        () async {
      final id = (await rowOfA()).id;
      // A second copy of a@test in Archive, seen while INBOX still had its
      // own; then the INBOX copy is deleted elsewhere.
      server.deliver('Archive', 'a@test');
      await sync('Archive');
      await sync('INBOX');
      final copyId =
          (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Archive').id;
      server.folders['INBOX']!.messages.clear();

      await sync('INBOX');

      final rows = {for (final e in await rowsOfA()) e.id: e.mailboxPath};
      expect(rows, {id: '', copyId: 'Archive'});
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });
  });

  group('no adoption when the pair cannot be the same mail', () {
    Iterable<String> notAdopted() => [
          for (final l in logsOf('email.foreign_move_not_adopted'))
            dataOf(l)['reason'] as String,
        ];

    test('another EMAILID', () async {
      await open(objectIds: true);
      final id = (await rowOfA()).id;
      server
        ..expungeElsewhere('a@test')
        ..deliver('Archive', 'a@test', emailId: 'E-other');

      await sync('INBOX');
      await sync('Archive');

      final shown =
          (await rowsOfA()).singleWhere((e) => e.mailboxPath == 'Archive');
      expect(shown.id, isNot(id));
      expect(notAdopted(), ['another server email id']);
    });

    test('another size', () async {
      await open();
      final id = (await rowOfA()).id;
      server.moveElsewhere('a@test', 'Archive');
      await sync('INBOX');
      await setRow(id, const EmailsCompanion(sizeBytes: Value(99)));

      await sync('Archive');

      expect((await rowOfA2(id)).srvGone, isTrue);
      expect(notAdopted(), ['another size']);
    });

    test('only the Message-ID agrees (a legacy row)', () async {
      await open();
      final id = (await rowOfA()).id;
      server.moveElsewhere('a@test', 'Archive');
      await sync('INBOX');
      await setRow(
        id,
        const EmailsCompanion(sizeBytes: Value(null), sentAt: Value(null)),
      );

      await sync('Archive');

      expect((await rowOfA2(id)).srvGone, isTrue);
      expect(notAdopted().single, startsWith('only the Message-ID agrees'));
    });

    test('a mail that left Sent', () async {
      await open(extra: [('Sent', 'sent')]);
      server.deliver('Sent', 's@test');
      await sync('Sent');
      final id = (await rigRowsOf('s@test')).single.id;
      server.moveElsewhere('s@test', 'Archive');

      await sync('Sent');
      expect((await rigRowsOf('s@test')).single.foreignMoveWaitSeq, isNotNull);
      await sync('Archive');

      final shown = (await rigRowsOf('s@test'))
          .singleWhere((e) => e.mailboxPath == 'Archive');
      expect(shown.id, isNot(id));
      expect(notAdopted(), ['across the Sent folder']);
    });

    test('a mail gone from Drafts does not wait', () async {
      await open(extra: [('Drafts', 'drafts')]);
      server.deliver('Drafts', 'd@test');
      await sync('Drafts');
      server.expungeElsewhere('d@test');

      await sync('Drafts');

      expect(await rigRowsOf('d@test'), isEmpty);
    });

    test('a row that changed before the carry-over is not retried', () async {
      await open();
      final id = (await rowOfA()).id;
      server.moveElsewhere('a@test', 'Archive');
      await sync('INBOX');
      // A move of the waiting row appears (another isolate queued it).
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _account.id,
              resourceType: 'Email',
              resourceId: id,
              changeType: 'move',
              payload: '{}',
              createdAt: now,
            ),
          );

      await sync('Archive');

      expect((await rowOfA2(id)).srvGone, isTrue);
      expect(notAdopted().single, startsWith('the row changed meanwhile'));
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });
  });
}
