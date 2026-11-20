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

import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

void main() {
  late RecordingAppLogRepository logs;
  useRigInboxArchive({'b@test': []}, (l) => logs = l);

  const rowsOf = rigRowsOf;
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

  /// Stores a row of [messageId] that the server does not have, recorded
  /// in [folder] at [uid] (null: no UID), as a sync at [seq] would.
  Future<void> storeRow(
    String messageId, {
    required String folder,
    int? uid,
    int seq = 1,
  }) =>
      EmailStateWriter(db).insertServerRow(
        ServerRowHeaders(
          uid: uid ?? 0,
          subject: messageId,
          sentAt: now,
          receivedAt: now,
          fromJson: '[]',
          toJson: '[]',
          ccJson: '[]',
          replyToJson: '[]',
          bccJson: '[]',
          hasAttachment: false,
          threadId: messageId,
          messageId: messageId,
          inReplyTo: null,
          references: null,
          srvUid: uid,
        ),
        id: 'acc-1:~$messageId',
        accountId: _account.id,
        mailboxPath: folder,
        keywords: const ServerKeywords(
          seen: false,
          flagged: false,
          snoozedUntil: null,
        ),
        seq: seq,
      );

  test(
      'a row recorded in a folder the account no longer has is swept once '
      'the folder list was read again', () async {
    await storeRow('orphan@test', folder: 'Removed', uid: 7);

    await emails.clearForResync(_account.id);
    expect(
      await rowsOf('orphan@test'),
      hasLength(1),
      reason: 'the clear itself sweeps nothing',
    );
    await emails.sweepRowsOutsideFolders(_account.id);

    expect(await rowsOf('orphan@test'), isEmpty);
    expect(await rowsOf('a@test'), hasLength(1), reason: 'INBOX is a folder');
    final line = swept().single;
    expect(line['mailboxPath'], isNull);
    await expectConsistent();
  });

  test('with no folder known from the server, nothing outside is swept',
      () async {
    await storeRow('orphan@test', folder: 'Removed', uid: 7);
    await db.delete(db.mailboxes).go();

    await emails.sweepRowsOutsideFolders(_account.id);

    expect(await rowsOf('orphan@test'), hasLength(1));
    expect(await rowsOf('a@test'), hasLength(1));
    expect(
      logs.inserts.map((r) => r['event']),
      contains('sync.resync_sweep_skipped'),
    );
    expect(swept(), isEmpty);
  });

  test(
      'a UIDVALIDITY changed before a folder resync leaves one row per mail '
      'and no body on another mail (B1)', () async {
    final a = await rowOfA();
    await cacheBodyOf(a.id);
    // The server renumbers INBOX: UID 1 is another mail now, a@test is 2.
    server.folders['INBOX'] = FakeServerFolder('INBOX', 99);
    server
      ..deliver('INBOX', 'x@test')
      ..deliver('INBOX', 'a@test');

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    for (final mid in ['a@test', 'x@test']) {
      final rows = await rowsOf(mid);
      expect(rows, hasLength(1), reason: '$mid stored once');
      expect(rows.single.srvUidValidity, 99);
    }
    expect(await rowsOf('b@test'), isEmpty, reason: 'gone with the reset');
    // a@test is found again by its Message-ID (#1314): same row, own body.
    expect((await rowOfA()).id, a.id);
    final aBody = await (db.select(db.emailBodies)
          ..where((t) => t.emailId.equals(a.id)))
        .getSingleOrNull();
    expect(aBody?.textBody, 'cached body');
    final x = (await rowsOf('x@test')).single;
    final xBody = await (db.select(db.emailBodies)
          ..where((t) => t.emailId.equals(x.id)))
        .getSingleOrNull();
    expect(xBody, isNull, reason: "not a@test's cached body");
    await expectConsistent();
  });

  test(
      'without a known previous UIDVALIDITY, rows stamped with another one '
      'and an unstamped row holding another mail are not taken over', () async {
    final a = await rowOfA();
    final bBefore = (await rowsOf('b@test')).single;
    await cacheBodyOf(a.id);
    // a@test's row recorded without a UIDVALIDITY (as before v70), and no
    // checkpoint to tell that the folder was renumbered.
    await db.customStatement(
      "UPDATE emails SET srv_uid_validity = NULL WHERE id = '${a.id}'",
    );
    await (db.delete(db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .go();
    server.folders['INBOX'] = FakeServerFolder('INBOX', 99);
    server
      ..deliver('INBOX', 'x@test')
      ..deliver('INBOX', 'b@test');

    await emails.syncEmails(_account.id, 'INBOX');

    final x = (await rowsOf('x@test')).single;
    expect(x.id, isNot(a.id), reason: 'UID 1 holds another mail now');
    final xBody = await (db.select(db.emailBodies)
          ..where((t) => t.emailId.equals(x.id)))
        .getSingleOrNull();
    expect(xBody, isNull);
    expect(await rowsOf('a@test'), isEmpty, reason: 'a stale duplicate');
    // Its row stamped 11 lost that UID and is found again by its
    // Message-ID (#1314), now stamped 99.
    final b = (await rowsOf('b@test')).single;
    expect(b.id, bBefore.id);
    expect(b.srvUidValidity, 99);
    expect(b.srvUid, 2);
    await expectConsistent();
  });

  test('a row without a UID is swept by the complete refetch', () async {
    await storeRow('nouid@test', folder: 'INBOX');

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    expect(await rowsOf('nouid@test'), isEmpty);
    expect(await rowsOf('a@test'), hasLength(1));
    await expectConsistent();
  });

  test('a row placed after the enumeration started is not swept', () async {
    await storeRow('late@test', folder: 'Archive', uid: 50);
    final late = (await rowsOf('late@test')).single;
    server.beforeAnswer = (command) async {
      if (command != 'SEARCH ALL (INBOX)') return;
      // A read started after the full fetch's UID SEARCH ALL places the
      // row in INBOX (e.g. a move's answer) while that answer is on its way.
      final read = await EmailStateWriter(db).beginRead(_account.id);
      await read.writeLocation(late.id, 'INBOX');
    };

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    final row = (await rowsOf('late@test')).single;
    expect(row.srvGone, isFalse, reason: 'newer than the enumeration');
    expect(row.mailboxPath, 'INBOX');
  });

  test('a header the refetch did not get keeps its stored value', () async {
    final a = await rowOfA();
    // The fake answers no preview snippet (like a failed snippet fetch).
    await db.customStatement(
      "UPDATE emails SET preview = 'stored preview', "
      "list_unsubscribe_header = '<mailto:u@x>' WHERE id = '${a.id}'",
    );

    await emails.clearMailboxForResync(_account.id, 'INBOX');
    await emails.syncEmails(_account.id, 'INBOX');

    final row = await rowOfA();
    expect(row.preview, 'stored preview');
    expect(row.listUnsubscribeHeader, '<mailto:u@x>');
  });
}
