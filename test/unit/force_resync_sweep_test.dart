// Force resync as mark-and-sweep (SYNC-REDESIGN.md §6 "Force resync",
// #1236, phase 6a), through the real IMAP sync on the stateful fake server:
// the clear deletes nothing, the refetch finds the cached rows again by
// their server location (they keep id and body), and only what the refetch
// did not find is removed, under the clean-up rule.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;
  setUp(() async {
    logs = await openRigInboxArchive();
    server.deliver('INBOX', 'b@test');
    await emails.syncEmails(_account.id, 'INBOX');
  });
  tearDown(() => db.close());

  Future<List<Email>> rowsOf(String messageId) =>
      (db.select(db.emails)..where((t) => t.messageId.equals(messageId))).get();
  Future<void> expectConsistent() async => expect(await rigProblems(), isEmpty);
  List<Map<String, Object?>> swept() => [
        for (final r in logs.inserts)
          if (r['event'] == 'sync.resync_swept') r,
      ];

  Future<void> cacheBodyOf(String emailId) => db.into(db.emailBodies).insert(
        EmailBodiesCompanion.insert(
          emailId: emailId,
          textBody: const Value('cached body'),
        ),
      );

  test(
      'a force resync deletes nothing up front, keeps what the refetch '
      'finds (id and body) and sweeps what the server lost', () async {
    final a = await rowOfA();
    final b = (await rowsOf('b@test')).single;
    await cacheBodyOf(a.id);
    server
      ..expungeElsewhere('b@test')
      ..deliver('INBOX', 'c@test');

    await emails.clearForResync(_account.id);
    await rig.mailboxes.clearForResync(_account.id);

    // Marked, not cleared: a refetch that never comes loses nothing.
    final shown = await emails.observeEmails(_account.id, 'INBOX').first;
    expect(shown.map((e) => e.id), containsAll([a.id, b.id]));
    final folders = await rig.mailboxes.observeMailboxes(_account.id).first;
    expect(folders, hasLength(2));

    await emails.syncEmails(_account.id, 'INBOX');

    expect((await rowOfA()).id, a.id, reason: 'found again in place');
    final body = await (db.select(db.emailBodies)
          ..where((t) => t.emailId.equals(a.id)))
        .getSingleOrNull();
    expect(body?.textBody, 'cached body');
    expect(await rowsOf('b@test'), isEmpty, reason: 'swept');
    expect(await rowsOf('c@test'), hasLength(1));
    final line = swept().single;
    expect(line['mailboxPath'], 'INBOX');
    final data =
        jsonDecode(line['dataJson']! as String) as Map<String, Object?>;
    expect(data['emailIds'], [b.id]);
    await expectConsistent();
  });

  test('the refetch writes the server state over a stale cached one', () async {
    final a = await rowOfA();
    server.setFlagElsewhere('a@test', r'\Seen', on: true);

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    final row = await rowOfA();
    expect(row.id, a.id);
    expect(row.isSeen, isTrue);
    expect(swept(), isEmpty, reason: 'nothing was lost');
    await expectConsistent();
  });

  test(
      'a mail the server lost stays while the user has a change of it, '
      'hidden, and is listed in the App Log', () async {
    final b = (await rowsOf('b@test')).single;
    await emails.setFlag(b.id, flagged: true);
    server.expungeElsewhere('b@test');

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    final row = (await rowsOf('b@test')).single;
    expect(row.srvGone, isTrue);
    expect(row.mailboxPath, '', reason: 'hidden');
    expect(await rigOps(), hasLength(1), reason: 'the star stays queued');
    expect(
      logs.inserts.map((r) => r['event']),
      contains('email.server_gone_with_changes'),
    );
    await expectConsistent();
  });

  test('a folder resync sweeps that folder only', () async {
    await emails.syncEmails(_account.id, 'Archive');
    server
      ..expungeElsewhere('b@test')
      ..expungeElsewhere('filler@test');

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    expect(await rowsOf('b@test'), isEmpty);
    expect(
      await rowsOf('filler@test'),
      hasLength(1),
      reason: 'Archive was not refetched, so nothing of it is swept',
    );
  });

  test(
      'a row recorded in a folder the account no longer has is swept by '
      'the account resync', () async {
    await EmailStateWriter(db).insertServerRow(
      ServerRowHeaders(
        uid: 7,
        subject: 'orphan',
        sentAt: now,
        receivedAt: now,
        fromJson: '[]',
        toJson: '[]',
        ccJson: '[]',
        replyToJson: '[]',
        bccJson: '[]',
        hasAttachment: false,
        threadId: 'orphan@test',
        messageId: 'orphan@test',
        inReplyTo: null,
        references: null,
        srvUid: 7,
      ),
      id: 'acc-1:~orphan',
      accountId: _account.id,
      mailboxPath: 'Removed',
      keywords: const ServerKeywords(
        seen: false,
        flagged: false,
        snoozedUntil: null,
      ),
      seq: 1,
    );

    await emails.clearForResync(_account.id);

    expect(await rowsOf('orphan@test'), isEmpty);
    expect(await rowsOf('a@test'), hasLength(1), reason: 'INBOX is a folder');
    final line = swept().single;
    expect(line['mailboxPath'], isNull);
    await expectConsistent();
  });
}
