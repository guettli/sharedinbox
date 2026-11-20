// A UIDVALIDITY change re-matches the cached rows by Message-ID
// (SYNC-REDESIGN.md §6, #1314), through the real IMAP sync on the stateful
// fake server: a row whose mail the renumbered folder still has, under a
// Message-ID unique on both sides, takes the new UID and keeps its id, body,
// downloaded attachments and queued changes. The others are swept, and the
// mail, if still there, comes back as a new row.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

void main() {
  const account = statefulRigAccount;
  late RecordingAppLogRepository logs;
  useRigInboxArchive(
    {
      'b@test': [],
      'c@test': [r'\Seen'],
      'd@test': [],
    },
    (recorder) => logs = recorder,
  );

  const rowsOf = rigRowsOf;
  Future<Email> rowOf(String messageId) async =>
      (await rowsOf(messageId)).single;
  Future<List<Email>> inboxRows() =>
      (db.select(db.emails)..where((t) => t.srvMailboxPath.equals('INBOX')))
          .get();
  Future<void> expectConsistent() async => expect(await rigProblems(), isEmpty);

  Future<void> cacheBodyOf(String emailId) async {
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value('cached body of $emailId'),
          ),
        );
    await db.into(db.attachmentFiles).insert(
          AttachmentFilesCompanion.insert(
            emailId: emailId,
            filename: 'file.pdf',
            size: 10,
            downloadedAt: DateTime.utc(2026),
          ),
        );
  }

  Future<String?> bodyOf(String emailId) async => (await (db.select(
        db.emailBodies,
      )..where((t) => t.emailId.equals(emailId)))
              .getSingleOrNull())
          ?.textBody;
  Future<int> attachmentsOf(String emailId) async => (await (db.select(
        db.attachmentFiles,
      )..where((t) => t.emailId.equals(emailId)))
              .get())
          .length;

  /// The data of the one `sync.uidvalidity_changed` line.
  Map<String, Object?> changedLine() {
    final line = logs.inserts
        .where((r) => r['event'] == 'sync.uidvalidity_changed')
        .single;
    expect(line['mailboxPath'], 'INBOX');
    return jsonDecode(line['dataJson']! as String) as Map<String, Object?>;
  }

  int serverUidOf(String messageId) => server.find(messageId)!.message.uid;

  test(
      'every mail is re-matched: same id, body and attachments, the new UID '
      'and UIDVALIDITY, the server flags', () async {
    const mids = ['a@test', 'b@test', 'c@test', 'd@test'];
    final before = {for (final mid in mids) mid: await rowOf(mid)};
    for (final row in before.values) {
      await cacheBodyOf(row.id);
    }
    // Reversed: each old UID names another mail now.
    server.renumberFolder('INBOX', 99, reverse: true);
    server.setFlagElsewhere('d@test', r'\Flagged', on: true);

    await emails.syncEmails(account.id, 'INBOX');

    expect(await inboxRows(), hasLength(mids.length), reason: 'no new row');
    for (final mid in mids) {
      final row = await rowOf(mid);
      expect(row.id, before[mid]!.id, reason: '$mid keeps its id');
      expect(row.srvUid, serverUidOf(mid));
      expect(row.uid, serverUidOf(mid));
      expect(row.srvUidValidity, 99);
      expect(row.srvGone, isFalse);
      expect(row.mailboxPath, 'INBOX');
      expect(await bodyOf(row.id), 'cached body of ${row.id}');
      expect(await attachmentsOf(row.id), 1);
    }
    expect((await rowOf('c@test')).isSeen, isTrue);
    expect((await rowOf('d@test')).isFlagged, isTrue);
    final data = changedLine();
    expect(data['rematched'], 4);
    expect(data['removed'], 0);
    await expectConsistent();

    // The next sync is incremental and changes nothing.
    await emails.syncEmails(account.id, 'INBOX');
    for (final mid in mids) {
      expect((await rowOf(mid)).id, before[mid]!.id);
    }
    await expectConsistent();
  });

  test(
      'mails sharing a Message-ID are not re-matched: their rows are swept '
      'and the mails come back as new rows', () async {
    server
      ..deliver('INBOX', 'dup@test')
      ..deliver('INBOX', 'dup@test');
    await emails.syncEmails(account.id, 'INBOX');
    final dupIds = {for (final row in await rowsOf('dup@test')) row.id};
    expect(dupIds, hasLength(2));
    final a = await rowOf('a@test');

    server.renumberFolder('INBOX', 99, reverse: true);
    await emails.syncEmails(account.id, 'INBOX');

    final dups = await rowsOf('dup@test');
    expect(dups, hasLength(2));
    for (final row in dups) {
      expect(dupIds, isNot(contains(row.id)), reason: 'a new row');
      expect(row.srvUidValidity, 99);
    }
    expect((await rowOf('a@test')).id, a.id, reason: 'unique: re-matched');
    final data = changedLine();
    expect(data['rematched'], 4);
    expect(data['removed'], 2);
    await expectConsistent();
  });

  test('a mail without a Message-ID comes back as a new row', () async {
    const noId = '${noMessageIdPrefix}1';
    server.deliver('INBOX', noId);
    await emails.syncEmails(account.id, 'INBOX');
    final old = (await inboxRows()).where((r) => r.messageId == null).single;
    await cacheBodyOf(old.id);
    final a = await rowOf('a@test');

    server.renumberFolder('INBOX', 99, reverse: true);
    await emails.syncEmails(account.id, 'INBOX');

    final fresh = (await inboxRows()).where((r) => r.messageId == null).single;
    expect(fresh.id, isNot(old.id));
    expect(fresh.srvUid, serverUidOf(noId));
    expect(fresh.srvUidValidity, 99);
    expect(await bodyOf(fresh.id), isNull, reason: 'no body of another row');
    expect((await rowOf('a@test')).id, a.id);
    expect(changedLine()['removed'], 1);
    await expectConsistent();
  });

  test(
      'a queued star of a re-matched row is flushed to its new UID, not to '
      'the mail that has its old one', () async {
    final a = await rowOf('a@test');
    final oldUid = a.srvUid;
    await emails.setFlag(a.id, flagged: true);

    server.renumberFolder('INBOX', 99, reverse: true);
    expect(server.folders['INBOX']!.messages[oldUid]!.messageId, 'd@test');
    await emails.syncEmails(account.id, 'INBOX');

    final op = (await rigOps()).single;
    expect(op.resourceId, a.id);
    final payload = jsonDecode(op.payload) as Map<String, Object?>;
    expect(payload['uid'], serverUidOf('a@test'));
    expect(payload['uidValidity'], 99);
    expect((await rowOf('a@test')).isFlagged, isTrue, reason: 'still folded');

    await emails.flushPendingChanges(account.id, 'pw');

    expect(server.find('a@test')!.message.flagged, isTrue);
    expect(server.find('d@test')!.message.flagged, isFalse);
    expect(
      server.hits,
      contains((command: r'STORE +\Flagged', messageId: 'a@test')),
    );
    await emails.syncEmails(account.id, 'INBOX');
    final row = await rowOf('a@test');
    expect(row.id, a.id);
    expect(row.isFlagged, isTrue);
    await expectConsistent();
  });

  test('a mail deleted during the change is dropped', () async {
    final a = await rowOf('a@test');
    final b = await rowOf('b@test');
    await cacheBodyOf(b.id);

    server
      ..renumberFolder('INBOX', 99)
      ..expungeElsewhere('b@test');
    await emails.syncEmails(account.id, 'INBOX');

    expect(await rowsOf('b@test'), isEmpty);
    expect(await bodyOf(b.id), isNull, reason: 'cascaded');
    expect((await rowOf('a@test')).id, a.id);
    final data = changedLine();
    expect(data['rematched'], 3);
    expect(data['removed'], 1);
    await expectConsistent();
  });

  test('a mail added during the change becomes a new row', () async {
    final a = await rowOf('a@test');

    server
      ..renumberFolder('INBOX', 99)
      ..deliver('INBOX', 'new@test');
    await emails.syncEmails(account.id, 'INBOX');

    final fresh = await rowOf('new@test');
    expect(fresh.srvUid, serverUidOf('new@test'));
    expect(fresh.srvUidValidity, 99);
    expect((await rowOf('a@test')).id, a.id);
    expect(await inboxRows(), hasLength(5));
    final data = changedLine();
    expect(data['rematched'], 4);
    expect(data['removed'], 0);
    await expectConsistent();
  });

  test(
      'a fetch that fails after the change removes nothing, and the next '
      'sync re-matches', () async {
    final a = await rowOf('a@test');
    await cacheBodyOf(a.id);
    server.renumberFolder('INBOX', 99, reverse: true);
    server.beforeAnswer = (command) async {
      if (command == 'FETCH headers (INBOX)') {
        throw Exception('connection lost');
      }
    };

    try {
      await emails.syncEmails(account.id, 'INBOX');
    } on Exception {
      // The lost connection fails the sync.
    }
    final released = await rowOf('a@test');
    expect(released.srvUid, isNull, reason: 'its old UID is forgotten');
    expect(released.mailboxPath, 'INBOX', reason: 'still shown');
    expect(await inboxRows(), hasLength(4));

    server.beforeAnswer = null;
    await emails.syncEmails(account.id, 'INBOX');

    final row = await rowOf('a@test');
    expect(row.id, a.id);
    expect(row.srvUidValidity, 99);
    expect(await bodyOf(a.id), isNotNull);
    expect(await inboxRows(), hasLength(4));
    await expectConsistent();
  });

  test('a force resync after the change re-matches the same way', () async {
    final a = await rowOf('a@test');
    await cacheBodyOf(a.id);
    server.renumberFolder('INBOX', 99, reverse: true);

    await emails.clearMailboxForResync(account.id, 'INBOX');
    await emails.syncEmails(account.id, 'INBOX');

    expect((await rowOf('a@test')).id, a.id);
    expect(await bodyOf(a.id), isNotNull);
    expect(await inboxRows(), hasLength(4));
    expect(changedLine()['rematched'], 4);
    await expectConsistent();
  });
}
