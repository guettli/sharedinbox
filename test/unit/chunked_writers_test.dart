// The long writers run in chunks, one transaction each (#1317, SYNC.md
// §5a): a big IMAP fetch and "mark all as read" over more mails than one
// chunk holds, and a chunk that fails after earlier ones committed. What a
// committed chunk wrote keeps its follow-up (threads, App Log lines).

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

/// More than two chunks of every chunked writer on the way.
const _mails = 450;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  setUp(() async {
    logs = RecordingAppLogRepository();
    final server = StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 11});
    for (var i = 0; i < _mails; i++) {
      server.deliver('INBOX', 'm$i@test');
    }
    rig = await StatefulImapRig.open(
      server,
      folders: [('INBOX', 'inbox')],
      appLogger: AppLogger(logs),
    );
  });
  tearDown(() => db.close());

  int logged(String event) => logs.rows.where((r) => r.event == event).length;
  Future<List<ThreadRow>> unreadThreads() =>
      (db.select(db.threads)..where((t) => t.hasUnread.equals(true))).get();

  test('a fetch over several chunks stores, threads and logs every mail',
      () async {
    final rows = await db.select(db.emails).get();
    expect(rows, hasLength(_mails));
    expect(await db.select(db.threads).get(), hasLength(_mails));
    expect(logged('email.fetched'), _mails);
    expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  });

  test('mark all as read over several chunks marks, threads and logs all',
      () async {
    await emails.markAllAsRead(statefulRigAccount.id, 'INBOX');

    final rows = await db.select(db.emails).get();
    expect(rows.where((e) => !e.isSeen), isEmpty);
    expect(await unreadThreads(), isEmpty);
    expect(logged('email.mark_read'), _mails);
    expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  });

  test(
      'mark all as read that fails in a later chunk keeps the earlier '
      'chunks complete: their threads and log lines', () async {
    // The 251st change fails: the first chunk (200) commits, the second
    // one rolls back.
    await db.customStatement(
      'CREATE TEMP TRIGGER fail_later_chunk BEFORE INSERT ON pending_changes '
      'WHEN (SELECT count(*) FROM pending_changes) >= 250 '
      "BEGIN SELECT RAISE(ABORT, 'boom'); END",
    );

    await expectLater(
      emails.markAllAsRead(statefulRigAccount.id, 'INBOX'),
      throwsA(anything),
    );

    final rows = await db.select(db.emails).get();
    final read = rows.where((e) => e.isSeen).toList();
    expect(read, hasLength(200), reason: 'one chunk');
    expect(await unreadThreads(), hasLength(_mails - 200));
    final unreadThreadIds = {for (final t in await unreadThreads()) t.id};
    for (final row in read) {
      expect(unreadThreadIds, isNot(contains(row.threadId ?? row.id)));
    }
    expect(logged('email.mark_read'), 200);
    expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  });
}
