// The window of a UIDVALIDITY change (#1314, SYNC-REDESIGN.md §6): between
// the server renumbering a folder and the full fetch that re-matches its
// rows, a cached row's UID names another mail. Nothing the app does then may
// take that other mail for the row's: no body, attachment or raw source is
// fetched by the old UID, a queued change reaches the right mail, a
// relocation records the UIDVALIDITY it learnt the UID under, a second sync
// does not release rows the first one already matched, and rows the sync
// could not match are neither left behind nor stored twice.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/data/db/database.dart';

import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _noId = '${noMessageIdPrefix}x';

void main() {
  const account = statefulRigAccount;
  late RecordingAppLogRepository logs;
  // INBOX: a@test 1, b@test 2, c@test 3, a mail without a Message-ID 4.
  useRigInboxArchive(
    {'b@test': [], 'c@test': [], _noId: []},
    (recorder) => logs = recorder,
  );

  Future<Email> rowOf(String messageId) async =>
      (await rigRowsOf(messageId)).single;
  Future<Email> rowWithoutMessageId() async =>
      (await (db.select(db.emails)..where((t) => t.messageId.isNull())).get())
          .single;
  Future<List<Email>> inboxRows() =>
      (db.select(db.emails)..where((t) => t.srvMailboxPath.equals('INBOX')))
          .get();
  Future<EmailBody?> cachedBodyOf(String emailId) =>
      (db.select(db.emailBodies)..where((t) => t.emailId.equals(emailId)))
          .getSingleOrNull();
  Iterable<String> events() => logs.inserts.map((r) => r['event']! as String);
  Future<int?> checkpointValidity(String folder) async {
    final row = await (db.select(db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:$folder')))
        .getSingle();
    return (jsonDecode(row.state) as Map<String, dynamic>)['uidValidity']
        as int?;
  }

  /// INBOX renumbered in reverse (UID 1 is the mail without a Message-ID
  /// now, a@test is 4), and a sync whose fetch fails after it released the
  /// rows: they wait without a UID.
  Future<void> openWindow() async {
    server.renumberFolder('INBOX', 99, reverse: true);
    server.beforeAnswer = (command) async {
      if (command == 'FETCH headers (INBOX)') throw Exception('lost');
    };
    try {
      await emails.syncEmails(account.id, 'INBOX');
    } on Exception {
      // The lost connection fails the sync.
    }
    server.beforeAnswer = null;
    expect((await rowOf('a@test')).srvUid, isNull);
    expect(events(), contains('sync.uidvalidity_refetch_failed'));
  }

  group('B1: the body of a row in the window', () {
    test('is fetched by its unique Message-ID, not by its old UID', () async {
      final a = await rowOf('a@test');
      await openWindow();

      final body = await emails.getEmailBody(a.id);

      expect(body.loadError, isNull);
      expect(body.textBody, contains('Body of a@test'));
      expect((await cachedBodyOf(a.id))!.textBody, contains('Body of a@test'));
    });

    test(
        'of a row without a Message-ID is not fetched (nor prefetched) and '
        'is available after the sync', () async {
      final row = await rowWithoutMessageId();
      await openWindow();

      for (final prefetch in [true, false]) {
        final body = await emails.getEmailBody(row.id, prefetch: prefetch);
        expect(body.loadError, isNotNull);
        expect(body.textBody, isNull);
      }
      expect(await cachedBodyOf(row.id), isNull, reason: 'nothing cached');
      expect(events(), contains('email.body.not_located'));

      // The re-match cannot match it: the mail comes back as a new row,
      // whose body is its own.
      await emails.syncEmails(account.id, 'INBOX');
      final fresh = await rowWithoutMessageId();
      expect(fresh.id, isNot(row.id));
      expect(
        (await emails.getEmailBody(fresh.id)).textBody,
        contains('Body of $_noId'),
      );
    });

    test(
        'of a row stamped with the old UIDVALIDITY, before any sync saw the '
        'change, is fetched by Message-ID', () async {
      final a = await rowOf('a@test');
      server.renumberFolder('INBOX', 99, reverse: true);

      final body = await emails.getEmailBody(a.id);

      expect(body.textBody, contains('Body of a@test'));
      expect(body.textBody, isNot(contains(_noId)));
    });

    test(
        'a fetched mail without a Message-ID is not the mail of a row with '
        'one', () async {
      final a = await rowOf('a@test');
      final noId = await rowWithoutMessageId();
      // A stale record: a@test's row names the UID of the other mail (whose
      // own row gives it up: one location, one row).
      await db.customStatement(
        'UPDATE emails SET srv_uid = NULL WHERE id = ?1',
        [noId.id],
      );
      await db.customStatement(
        'UPDATE emails SET srv_uid = ?1, uid = ?1 WHERE id = ?2',
        [noId.srvUid, a.id],
      );

      final body = await emails.getEmailBody(a.id);

      expect(body.textBody, contains('Body of a@test'));
      final healed = await rowOf('a@test');
      expect(healed.srvUid, server.find('a@test')!.message.uid);
    });
  });

  group('B2: attachments and the raw source in the window', () {
    const attachment = model.EmailAttachment(
      filename: 'file.txt',
      contentType: 'text/plain',
      size: 10,
      fetchPartId: '1',
    );

    test('of a row without a Message-ID are refused, nothing saved', () async {
      final row = await rowWithoutMessageId();
      await openWindow();
      final commands = <String>[];
      server.beforeAnswer = (command) async => commands.add(command);

      await expectLater(
        emails.downloadAttachment(row.id, attachment),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        emails.fetchRawRfc822(row.id),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.attachmentFiles).get(), isEmpty);
      expect(
        commands.where((c) => c.startsWith('FETCH body')),
        isEmpty,
        reason: 'no mail was fetched',
      );
    });

    test("another mail's part is never saved as the row's attachment",
        () async {
      final a = await rowOf('a@test');
      final b = await rowOf('b@test');
      // A stale record under the current UIDVALIDITY: a@test's row names
      // b@test's UID (b@test's row gives it up: one location, one row).
      await db.customStatement(
        'UPDATE emails SET srv_uid = NULL WHERE id = ?1',
        [b.id],
      );
      await db.customStatement(
        'UPDATE emails SET srv_uid = ?1 WHERE id = ?2',
        [b.srvUid, a.id],
      );

      await expectLater(
        emails.downloadAttachment(a.id, attachment),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        emails.fetchRawRfc822(a.id),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.attachmentFiles).get(), isEmpty);
      expect(
        Directory('${rig.cacheDir.path}/sharedinbox/attachments').existsSync(),
        isFalse,
      );
      expect(events(), contains('email.body.identity_mismatch'));
    });

    test('the raw source of a row with a Message-ID is its own', () async {
      final a = await rowOf('a@test');
      await openWindow();

      final raw = await emails.fetchRawRfc822(a.id);

      expect(raw, contains('<a@test>'));
    });
  });

  test(
      'a star, a move and a delete queued on released rows reach their mails '
      'by Message-ID, not the mails that have their old UIDs', () async {
    await openWindow();
    final a = await rowOf('a@test');
    final b = await rowOf('b@test');
    final c = await rowOf('c@test');
    await emails.setFlag(a.id, flagged: true);
    await emails.moveEmail(b.id, 'Archive');
    await emails.deleteEmail(c.id);
    server.hits.clear();

    await emails.flushPendingChanges(account.id, 'pw');

    expect(server.hits, [
      (command: r'STORE +\Flagged', messageId: 'a@test'),
      (command: 'MOVE INBOX->Archive', messageId: 'b@test'),
      (command: r'STORE +\Deleted', messageId: 'c@test'),
      (command: 'EXPUNGE', messageId: 'c@test'),
    ]);
    expect(server.find('a@test')!.message.flagged, isTrue);
    expect(server.find('b@test')!.folder.path, 'Archive');
    expect(server.find('c@test'), isNull);
    expect(server.find(_noId), isNotNull, reason: 'untouched');

    await emails.syncEmails(account.id, 'INBOX');
    await emails.syncEmails(account.id, 'Archive');
    final row = await rowOf('a@test');
    expect(row.id, a.id);
    expect(row.isFlagged, isTrue);
    expect((await rowOf('b@test')).id, b.id);
    // Deleted for good: hidden, and gone once its acked delete settles.
    expect(
      (await rigRowsOf('c@test')).map((r) => (r.mailboxPath, r.srvGone)),
      everyElement(('', true)),
    );
    expect(await rigProblems(), isEmpty);
  });

  test(
      'a move flushed while the full fetch answer is on its way does not '
      'store the mail a second time (stale-answer fuzz seed 167)', () async {
    final a = await rowOf('a@test');
    server.renumberFolder('INBOX', 99, reverse: true);
    // Queued under the old UIDVALIDITY (11), so its UID names another mail.
    await emails.moveEmail(a.id, 'Archive');
    var flushed = false;
    server.beforeAnswer = (command) async {
      if (command != 'FETCH headers (INBOX)' || flushed) return;
      flushed = true;
      // The answer lists a@test in INBOX; the move reaches the server first.
      await emails.flushPendingChanges(account.id, 'pw');
    };

    await emails.syncEmails(account.id, 'INBOX');
    server.beforeAnswer = null;
    await emails.syncEmails(account.id, 'Archive');

    expect(flushed, isTrue);
    expect(server.find('a@test')!.folder.path, 'Archive');
    final rows = await rigRowsOf('a@test');
    expect(rows.map((r) => r.id), [a.id], reason: 'one row, its own');
    expect(rows.single.mailboxPath, 'Archive');
    expect(await rigProblems(), isEmpty);
  });

  test(
      'a second copy of a moved mail that arrives later is stored, though '
      'the move was queued under the old UIDVALIDITY', () async {
    final a = await rowOf('a@test');
    server.renumberFolder('INBOX', 99, reverse: true);
    await emails.moveEmail(a.id, 'Archive');
    await emails.flushPendingChanges(account.id, 'pw');
    // The move is applied, not yet confirmed by a read of Archive (acked).
    expect(
      (await rigOps()).map((op) => (op.changeType, op.state)),
      contains(('move', 'acked')),
    );
    await emails.syncEmails(account.id, 'INBOX');

    // A second copy (a self CC, a list duplicate) arrives in INBOX: the
    // incremental fetch lists it alone.
    server.deliver('INBOX', 'a@test');
    await emails.syncEmails(account.id, 'INBOX');

    final rows = await rigRowsOf('a@test');
    expect(rows, hasLength(2));
    expect(
      rows.map((r) => r.srvMailboxPath).toSet(),
      {'Archive', 'INBOX'},
    );
    expect(rows.firstWhere((r) => r.srvMailboxPath == 'Archive').id, a.id);
  });

  group('N1: a fetched header that does not read like the envelope', () {
    for (final (what, header) in [
      ('with a comment after it', '<odd@test> (added by a relay)'),
      ('missing', ''),
    ]) {
      test('$what: the body opens, the search confirms the mail', () async {
        server.deliver('INBOX', 'odd@test', messageIdHeader: header);
        await emails.syncEmails(account.id, 'INBOX');
        final odd = await rowOf('odd@test');

        final body = await emails.getEmailBody(odd.id);

        expect(body.loadError, isNull);
        expect(body.textBody, contains('Body of odd@test'));
        expect((await rowOf('odd@test')).srvUid, odd.srvUid);
      });
    }
  });

  group('S1: a renumbered folder the server does not enumerate', () {
    test(
        'keeps its rows and the old checkpoint until it does, then '
        're-matches them', () async {
      final a = await rowOf('a@test');
      server
        ..renumberFolder('INBOX', 99, reverse: true)
        ..searchAllEmpty = true;

      for (var i = 0; i < 2; i++) {
        await emails.syncEmails(account.id, 'INBOX');
        expect(await inboxRows(), hasLength(4));
        expect(await checkpointValidity('INBOX'), 11);
      }
      expect(
        events().where((e) => e == 'sync.uidvalidity_rematch_deferred'),
        hasLength(1),
        reason: 'once per folder and UIDVALIDITY',
      );

      server.searchAllEmpty = false;
      await emails.syncEmails(account.id, 'INBOX');

      expect(await inboxRows(), hasLength(4), reason: 'one row per mail');
      expect((await rowOf('a@test')).id, a.id);
      expect(await checkpointValidity('INBOX'), 99);
      expect(await rigProblems(), isEmpty);
    });

    test(
        'gives up after a day and three tries: the unmatched rows are '
        'removed and the new checkpoint saved', () async {
      server
        ..renumberFolder('INBOX', 99, reverse: true)
        ..searchAllEmpty = true;

      for (var i = 0; i < 3; i++) {
        await emails.syncEmails(account.id, 'INBOX');
        expect(await inboxRows(), hasLength(4), reason: 'try ${i + 1}');
      }
      expect(await checkpointValidity('INBOX'), 11, reason: 'not a day yet');

      now = now.add(const Duration(hours: 25));
      await emails.syncEmails(account.id, 'INBOX');

      expect(await inboxRows(), isEmpty);
      expect(await checkpointValidity('INBOX'), 99);
      expect(events(), contains('sync.uidvalidity_rematch_given_up'));
      expect(await rigProblems(), isEmpty);

      // The server lists its mail again: it comes back as new rows.
      server.searchAllEmpty = false;
      await emails.syncEmails(account.id, 'INBOX');
      expect(await inboxRows(), hasLength(4));
    });

    test(
        'released rows left behind are swept by the incremental reconcile '
        'once every listed mail has its own row', () async {
      // As if a sync had saved the new UIDVALIDITY without matching the
      // rows (before #1314's fix): released rows and a checkpoint at 99.
      server.renumberFolder('INBOX', 99, reverse: true);
      await db.customStatement(
        'UPDATE emails SET srv_uid = NULL, srv_uid_validity = NULL '
        "WHERE srv_mailbox_path = 'INBOX'",
      );
      await db.customStatement(
        'UPDATE sync_states SET state = ?1 '
        "WHERE resource_type = 'IMAP:INBOX'",
        [
          jsonEncode({'uidValidity': 99, 'lastUid': 0}),
        ],
      );

      await emails.syncEmails(account.id, 'INBOX');

      for (final mid in ['a@test', 'b@test', 'c@test']) {
        expect(await rigRowsOf(mid), hasLength(1), reason: '$mid once');
      }
      expect(await inboxRows(), hasLength(4));
      expect(events(), contains('sync.unlocated_swept'));
      expect(await rigProblems(), isEmpty);
    });
  });

  test(
      'S2: a move into a renumbered folder records the UIDVALIDITY of its '
      'COPYUID, and the sync keeps that row', () async {
    final a = await rowOf('a@test');
    server.renumberFolder('Archive', 77);

    await emails.moveEmail(a.id, 'Archive');
    await emails.flushPendingChanges(account.id, 'pw');

    final moved = await rowOf('a@test');
    expect(moved.srvMailboxPath, 'Archive');
    expect(moved.srvUid, server.find('a@test')!.message.uid);
    expect(moved.srvUidValidity, 77, reason: "not the checkpoint's 22");

    await emails.syncEmails(account.id, 'Archive');

    final row = await rowOf('a@test');
    expect(row.id, a.id);
    expect(row.srvUidValidity, 77);
    expect((await rigRowsOf('filler@test')).single.srvUidValidity, 77);
    expect(await rigProblems(), isEmpty);
  });

  test(
      'S3: a second sync that read the old checkpoint does not release the '
      'rows the first one matched', () async {
    final before = {
      for (final row in await inboxRows()) row.messageId: row.id,
    };
    server.renumberFolder('INBOX', 99, reverse: true);
    await emails.syncEmails(account.id, 'INBOX');
    final matched = {
      for (final row in await inboxRows())
        row.id: (row.srvUid, row.srvUidValidity),
    };
    // The other isolate loaded the checkpoint before this one saved it.
    await db.customStatement(
      'UPDATE sync_states SET state = ?1 '
      "WHERE resource_type = 'IMAP:INBOX'",
      [
        jsonEncode({'uidValidity': 11, 'lastUid': 4}),
      ],
    );

    await emails.syncEmails(account.id, 'INBOX');

    final after = await inboxRows();
    expect(
      {for (final row in after) row.id: (row.srvUid, row.srvUidValidity)},
      matched,
    );
    for (final row in after) {
      if (row.messageId == null) continue;
      expect(row.id, before[row.messageId], reason: '${row.messageId}');
    }
    expect(
      events().where((e) => e == 'sync.uidvalidity_changed'),
      hasLength(1),
      reason: 'the second sync matched and removed nothing',
    );
  });
}
