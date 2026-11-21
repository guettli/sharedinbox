// #1328: a mail that another IMAP client moved must show in the list of
// the folder its row shows in (the thread rows the list screen reads,
// `observeThreads`), not only in search and the folder counter. A mail
// with no Message-ID and no Date is its own thread, keyed by its row id:
// the carry-over took the merged copy's key, the thread kept the old one,
// and the next sweep dropped it as an orphan.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;
const _noMid = '${noMessageIdPrefix}x';
const _folders = ['INBOX', 'Archive', 'Jobs'];

void main() {
  setUpAll(configureSqliteForTests);
  tearDown(() => db.close());

  late RecordingAppLogRepository logs;

  Future<void> open({required bool objectIds, required bool dated}) async {
    logs = RecordingAppLogRepository();
    final server = StatefulFakeImapServer(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Jobs': 33},
      objectIds: objectIds,
    )
      ..deliver('INBOX', 'a@test')
      ..deliver('INBOX', _noMid, dated: dated)
      // So a mail moved to Archive gets another UID than it had in INBOX.
      ..deliver('Archive', 'filler@test');
    rig = await StatefulImapRig.open(
      server,
      folders: [('INBOX', 'inbox'), ('Archive', 'archive'), ('Jobs', '')],
      appLogger: AppLogger(logs),
    );
    await emails.syncEmails(_account.id, 'Archive');
    await emails.syncEmails(_account.id, 'Jobs');
  }

  Future<void> sync(String folder) => emails.syncEmails(_account.id, folder);
  Future<void> flush() => emails.flushPendingChanges(_account.id, 'pw');

  /// What the list screen shows for [folder]: thread id → its email ids.
  Future<Map<String, Set<String>>> listed(String folder) async => {
        for (final t in await emails.observeThreads(_account.id, folder).first)
          t.threadId: t.emailIds.toSet(),
      };

  /// The thread rows of each folder are exactly the rows shown there,
  /// grouped by their thread key (`threadId ?? id`).
  Future<void> expectListsMatchRows(String step) async {
    final rows = await db.select(db.emails).get();
    for (final folder in _folders) {
      final byThread = <String, Set<String>>{};
      for (final e in rows) {
        if (e.mailboxPath != folder) continue;
        (byThread[e.threadId ?? e.id] ??= {}).add(e.id);
      }
      expect(await listed(folder), byThread, reason: '$folder after $step');
    }
  }

  Iterable<String> repairs() => [
        for (final l in logs.rows)
          if (l.event == 'thread.list_repaired') l.message,
      ];

  Future<Email> rowOfNoMid() async => (await db.select(db.emails).get())
      .singleWhere((e) => e.messageId == null);

  /// Queues [queued] ('+'-separated: `seen`, `flagged`, `move <folder>`)
  /// for row [id].
  Future<void> queue(String id, String queued) async {
    for (final change in queued.split('+')) {
      switch (change.split(' ')) {
        case ['seen']:
          await emails.setFlag(id, seen: true);
        case ['flagged']:
          await emails.setFlag(id, flagged: true);
        case ['move', final folder]:
          await emails.moveEmail(id, folder);
      }
    }
  }

  /// Another client moves the mail to Archive while [queued] waits; three
  /// sync cycles follow (flush and folders in the given order), and after
  /// every step each folder's list matches its rows.
  void movedElsewhere({
    required bool dated,
    required bool objectIds,
    required bool destinationFirst,
    required bool flushFirst,
    required String queued,
  }) {
    test(
        'dated: $dated, EMAILID: $objectIds, destination first: '
        '$destinationFirst, flush first: $flushFirst, queued: $queued',
        () async {
      await open(objectIds: objectIds, dated: dated);
      await queue((await rowOfNoMid()).id, queued);
      await expectListsMatchRows('queueing');
      server.moveElsewhere(_noMid, 'Archive');

      for (var cycle = 0; cycle < 3; cycle++) {
        if (flushFirst) await flush();
        await expectListsMatchRows('cycle $cycle, flush');
        for (final folder in destinationFirst
            ? ['Archive', 'INBOX', 'Jobs']
            : ['INBOX', 'Archive', 'Jobs']) {
          await sync(folder);
          await expectListsMatchRows('cycle $cycle, $folder');
        }
        if (!flushFirst) await flush();
        await expectListsMatchRows('cycle $cycle, last flush');
      }

      final shown = (await db.select(db.emails).get()).where(
        (e) => e.messageId == null && e.mailboxPath.isNotEmpty,
      );
      expect(
        [for (final e in shown) e.mailboxPath],
        [server.find(_noMid)!.folder.path],
      );
      // Fixed at the source: nothing for the sync to repair.
      expect(repairs(), isEmpty);
      expect(await rigProblems(), isEmpty);
    });
  }

  const queuedChanges = [
    'none',
    'seen',
    'flagged+seen',
    'move Jobs',
    'move Archive',
    'seen+move Jobs',
    'seen+move Archive',
  ];

  group('a mail without a Message-ID moved by another client is listed', () {
    // The carry-over path: an EMAILID matches the rows, and without a Date
    // the thread id is the row id.
    for (final destinationFirst in [true, false]) {
      for (final flushFirst in [true, false]) {
        for (final queued in queuedChanges) {
          movedElsewhere(
            dated: false,
            objectIds: true,
            destinationFirst: destinationFirst,
            flushFirst: flushFirst,
            queued: queued,
          );
        }
      }
    }
    // A dated subject thread, or no EMAILID (no carry-over): a cheaper
    // subset.
    for (final (dated, objectIds) in [
      (true, true),
      (true, false),
      (false, false),
    ]) {
      for (final destinationFirst in [true, false]) {
        for (final queued in ['none', 'seen+move Jobs']) {
          movedElsewhere(
            dated: dated,
            objectIds: objectIds,
            destinationFirst: destinationFirst,
            flushFirst: true,
            queued: queued,
          );
        }
      }
    }
  });

  test('a carried-over row keeps its own id as its thread id', () async {
    await open(objectIds: true, dated: false);
    final id = (await rowOfNoMid()).id;
    server.moveElsewhere(_noMid, 'Archive');
    await sync('Archive');
    await sync('INBOX');

    final e = await rowOfNoMid();
    expect((e.id, e.mailboxPath, e.threadId), (id, 'Archive', id));
    expect((await listed('Archive'))[id], {id});
  });

  test('a row listed only under another thread key is listed under its own',
      () async {
    await open(objectIds: true, dated: false);
    final id = (await rowOfNoMid()).id;
    server.moveElsewhere(_noMid, 'Archive');
    await sync('Archive');
    await sync('INBOX');
    final filler = (await db.select(db.emails).get())
        .singleWhere((e) => e.messageId == 'filler@test')
        .id;
    // The row's thread row (key: its id) still lists it, and stays backed
    // (the filler has that key now), but the row's own key is another one.
    await (db.update(db.emails)..where((t) => t.id.equals(filler)))
        .write(EmailsCompanion(threadId: Value(id)));
    await (db.update(db.emails)..where((t) => t.id.equals(id)))
        .write(const EmailsCompanion(threadId: Value('acc-1:~gone')));

    await sync('Archive');

    expect(await listed('Archive'), {
      id: {filler},
      'acc-1:~gone': {id},
    });
    final data = jsonDecode(
      logs.rows.singleWhere((l) => l.event == 'thread.list_repaired').dataJson!,
    ) as Map<String, dynamic>;
    expect((data['emailIds'] as List).toSet(), {id, filler});
  });

  test('a row left unlisted is listed again by its folder sync', () async {
    await open(objectIds: true, dated: false);
    final id = (await rowOfNoMid()).id;
    server.moveElsewhere(_noMid, 'Archive');
    await sync('Archive');
    await sync('INBOX');
    // What the carry-over left in databases before the fix: the thread id
    // of the merged copy, and no thread row listing the mail.
    await (db.update(db.emails)..where((t) => t.id.equals(id)))
        .write(const EmailsCompanion(threadId: Value('acc-1:~gone')));
    await (db.delete(db.threads)..where((t) => t.id.equals(id))).go();
    expect(
      (await listed('Archive')).values.expand((ids) => ids),
      isNot(contains(id)),
    );

    await sync('Archive');

    expect((await listed('Archive'))['acc-1:~gone'], {id});
    await expectListsMatchRows('the repair');
    final repaired =
        logs.rows.singleWhere((l) => l.event == 'thread.list_repaired');
    expect(repaired.mailboxPath, 'Archive');
    expect(repaired.message, contains('1 mail(s) of Archive'));
    final data = jsonDecode(repaired.dataJson!) as Map<String, dynamic>;
    expect(data['emailIds'], [id]);

    // Listed now: nothing more to repair.
    await sync('Archive');
    expect(repairs(), hasLength(1));
  });
}
