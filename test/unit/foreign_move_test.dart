// When another client moves a mail, sync sees it vanish from one folder and
// appear in another with the same move-stable server id (RFC 8474 EMAILID).
// The row carries over with its id (SYNC-REDESIGN.md §6, phase 2c): the row
// sync stored at the new place is merged into it, never the other way round.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  setUp(() async {
    logs = RecordingAppLogRepository();
    rig = await StatefulImapRig.open(
      StatefulFakeImapServer(
        uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Spam': 33},
        objectIds: true,
      )
        ..deliver('INBOX', 'a@test')
        // So the moved mail gets another UID in Archive than in INBOX.
        ..deliver('Archive', 'filler@test'),
      folders: [('INBOX', 'inbox'), ('Archive', 'archive'), ('Spam', 'junk')],
      appLogger: AppLogger(logs),
    );
    await emails.syncEmails(_account.id, 'Archive');
  });
  tearDown(() => db.close());

  Future<List<Email>> rowsOfA() =>
      (db.select(db.emails)..where((t) => t.messageId.equals('a@test'))).get();
  Future<Email> rowOfA() async => (await rowsOfA()).single;

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
    expect(await db.select(db.pendingChanges).get(), isEmpty);
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
}
