// Another client moves a mail from INBOX to Archive, and this device syncs
// INBOX first (#1313). The absence rule finds the mail gone; with a
// Message-ID its row waits, hidden, until another folder's sync stores the
// mail: that sync adopts it, and the row keeps its id, body, attachments and
// references. When no folder receives it (a delete elsewhere), the wait ends
// once every other folder synced since, or after
// EmailStateWriter.foreignMoveMaxWait, and the clean-up rule removes it.

import 'dart:convert';

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
      server.moveElsewhere('a@test', 'Archive');

      await sync('INBOX');

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
      final unread = await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM emails '
            "WHERE mailbox_path <> '' AND is_seen = 0",
          )
          .getSingle();
      expect(unread.read<int>('n'), 1); // the filler in Archive
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
        (data['removedEmailId'], data['from'], data['body']),
        (id, 'INBOX', true),
      );
      expect(logsOf('email.foreign_move_adopted'), isEmpty);
    });

    test('without a cached body the expiry is logged as info', () async {
      server.expungeElsewhere('a@test');

      await sync('INBOX');
      await sync('Archive');
      await sync('Spam');

      expect(await rowsOfA(), isEmpty);
      final expired = logsOf('email.foreign_move_wait_expired').single;
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
      expect(logsOf('email.foreign_move_wait_expired'), hasLength(1));
    });

    test('a mail that arrives after the wait ended gets a new row', () async {
      final id = (await rowOfA()).id;
      server.expungeElsewhere('a@test');
      await sync('INBOX');
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
      await sync('Archive');
      await sync('Spam');
      expect((await rowsOfA()).map((e) => e.id), isNot(contains(id)));
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
}
