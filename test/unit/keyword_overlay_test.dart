// The `keywords` overlay (SYNC-REDESIGN.md §2–§5, phase 3a): read/star/
// snooze state is `COALESCE(local_*, srv_*)`, sync writes `srv_*` only
// through the server-write gate in read order, a change the server applied
// is acked and keeps showing until a later read confirms it.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

const _unread = ServerKeywords(seen: false, flagged: false, snoozedUntil: null);
const _read = ServerKeywords(seen: true, flagged: false, snoozedUntil: null);

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() async {
    rig = await StatefulImapRig.open(
      StatefulFakeImapServer(
        uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Snoozed': 33},
      )..deliver('INBOX', 'a@test'),
      folders: [
        ('INBOX', 'inbox'),
        ('Archive', 'archive'),
        ('Snoozed', 'snoozed'),
      ],
    );
  });
  tearDown(() => db.close());

  Future<Email> mail([String messageId = 'a@test']) async =>
      (await db.select(db.emails).get())
          .singleWhere((e) => e.messageId == messageId);
  Future<List<PendingChangeRow>> ops() => db.select(db.pendingChanges).get();
  EmailStateWriter writer({AppLogger? appLogger}) =>
      EmailStateWriter(db, appLogger: appLogger);
  Future<void> expectConsistent() async =>
      expect(await writer().consistencyProblems(), isEmpty);
  Future<void> sync([String folder = 'INBOX']) =>
      emails.syncEmails(_account.id, folder);
  Future<void> flush() => emails.flushPendingChanges(_account.id, 'pw');

  /// Makes the next sync of [folder] re-read every flag.
  Future<void> reconcileNext(String folder) => (db.delete(db.syncStates)
        ..where((t) => t.resourceType.equals('IMAP:FlagReconcile:$folder')))
      .go();

  test('a user change folds over the server value', () async {
    final id = (await mail()).id;

    await emails.setFlag(id, seen: true);

    final e = await mail();
    expect(e.isSeen, isTrue);
    expect(e.localIsSeen, isTrue);
    expect(e.srvIsSeen, isFalse, reason: 'srv_ is what the server said');
    expect((await ops()).single.state, 'pending');
    await expectConsistent();
  });

  test('a read that started before a faster one is ignored', () async {
    final id = (await mail()).id;
    final slow = await writer().beginRead(_account.id);
    final fast = await writer().beginRead(_account.id);

    expect((await fast.write(id, _read)).written, isTrue);
    expect((await slow.write(id, _unread)).written, isFalse);

    final e = await mail();
    expect(e.isSeen, isTrue);
    expect(e.srvIsSeen, isTrue);
    expect(e.srvKeywordsSeq, fast.seq);
    await expectConsistent();
  });

  test("a stale FETCH answer after the user's change keeps the change",
      () async {
    final id = (await mail()).id;
    await reconcileNext('INBOX');
    server.beforeAnswer = (command) async {
      if (command != 'FETCH FLAGS (INBOX)') return;
      server.beforeAnswer = null;
      // The answer (unread) is fixed; the user reads the mail meanwhile.
      await emails.setFlag(id, seen: true);
    };

    await sync();

    final e = await mail();
    expect(e.isSeen, isTrue);
    expect(e.srvIsSeen, isFalse);
    await flush();
    expect(server.find('a@test')!.message.seen, isTrue);
    await expectConsistent();
  });

  test(
      'an answer that started before the ack does not flip the mail back; '
      'a later read drops the acked change', () async {
    final id = (await mail()).id;
    await reconcileNext('INBOX');
    server.beforeAnswer = (command) async {
      if (command != 'FETCH FLAGS (INBOX)') return;
      server.beforeAnswer = null;
      // Read, and sent, while the stale answer is on its way.
      await emails.setFlag(id, seen: true);
      await flush();
      expect((await ops()).single.state, 'acked');
    };

    await sync();

    var e = await mail();
    expect(e.srvIsSeen, isFalse, reason: 'the stale answer was written');
    expect(e.isSeen, isTrue, reason: 'the acked change still folds');
    expect((await ops()).single.state, 'acked');
    await expectConsistent();

    // The STORE bumped the MODSEQ: the next sync reads the flags again.
    await sync();

    e = await mail();
    expect(await ops(), isEmpty);
    expect(e.isSeen, isTrue);
    expect(e.srvIsSeen, isTrue);
    expect(e.localIsSeen, isNull);
    await expectConsistent();
  });

  test('an acked change shows until the next read, which drops it', () async {
    final id = (await mail()).id;
    await emails.setFlag(id, flagged: true);
    await flush();

    var e = await mail();
    final acked = (await ops()).single;
    expect(acked.state, 'acked');
    expect(acked.ackSeq, isNotNull);
    expect(e.isFlagged, isTrue);
    expect(e.srvIsFlagged, isFalse);

    await sync();

    e = await mail();
    expect(await ops(), isEmpty);
    expect(e.isFlagged, isTrue);
    expect(e.srvIsFlagged, isTrue);
    await expectConsistent();
  });

  test(
      'an acked change two reads contradict is dropped with an App Log '
      'line', () async {
    final logs = RecordingAppLogRepository();
    final w = writer(appLogger: AppLogger(logs));
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    await flush();
    expect((await ops()).single.state, 'acked');

    // Two reads after the ack still say unread (a lagging server, or
    // another client marked it unread again).
    final first = await w.beginRead(_account.id);
    await first.write(id, _unread);
    expect((await ops()).single.contradictedSeq, first.seq);
    expect((await mail()).isSeen, isTrue, reason: 'one read is not enough');

    final second = await w.beginRead(_account.id);
    await second.write(id, _unread);
    await pumpEventQueue();

    expect(await ops(), isEmpty);
    expect((await mail()).isSeen, isFalse);
    expect([for (final r in logs.rows) r.event], contains('op.contradicted'));
    await expectConsistent();
  });

  test('a failed change stops folding: the server value shows again', () async {
    final id = (await mail()).id;
    server.refuses = (_) => true;
    await emails.setFlag(id, seen: true);
    expect((await mail()).isSeen, isTrue);

    await flush();

    final e = await mail();
    expect((await ops()).single.state, 'failed');
    expect(e.isSeen, isFalse);
    expect(e.localIsSeen, isNull);
    // The flag reconcile of the folder is due: the server is read again.
    final due = await (db.select(db.syncStates)
          ..where(
            (t) => t.resourceType.equals('IMAP:FlagReconcileDue:INBOX'),
          ))
        .getSingleOrNull();
    expect(due, isNotNull);
    await expectConsistent();
  });

  test('a stuck change keeps folding over server reads', () async {
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    await db.update(db.pendingChanges).write(
          const PendingChangesCompanion(state: Value('stuck')),
        );
    await writer().refold(id);
    final read = await writer().beginRead(_account.id);
    await read.write(id, _unread);

    final e = await mail();
    expect(e.isSeen, isTrue);
    expect(e.srvIsSeen, isFalse);
    await expectConsistent();
  });

  test('a newer read change supersedes a queued one', () async {
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    await emails.setFlag(id, seen: false);

    final queued = await ops();
    expect(queued, hasLength(1));
    expect(queued.single.payload, contains('"seen":false'));
    expect((await mail()).isSeen, isFalse);
    await expectConsistent();
  });

  test('mark all as read folds every mail at once', () async {
    server
      ..deliver('INBOX', 'b@test')
      ..deliver('INBOX', 'c@test');
    await sync();

    await emails.markAllAsRead(_account.id, 'INBOX');

    for (final m in ['a@test', 'b@test', 'c@test']) {
      final e = await mail(m);
      expect(e.isSeen, isTrue, reason: m);
      expect(e.localIsSeen, isTrue, reason: m);
      expect(e.srvIsSeen, isFalse, reason: m);
    }
    expect(await ops(), hasLength(3));
    await expectConsistent();

    await flush();
    await sync();

    expect(await ops(), isEmpty);
    for (final m in ['a@test', 'b@test', 'c@test']) {
      final e = await mail(m);
      expect(e.isSeen, isTrue, reason: m);
      expect(e.localIsSeen, isNull, reason: m);
      expect(e.srvIsSeen, isTrue, reason: m);
    }
    await expectConsistent();
  });

  test('a snooze shows its wake-up time until a read confirms it', () async {
    final id = (await mail()).id;
    final until = DateTime.utc(2026, 12, 1, 8);

    await emails.snoozeEmail(id, until);

    var e = await mail();
    expect(e.snoozedUntil!.isAtSameMomentAs(until), isTrue);
    expect(e.srvSnoozedUntil, isNull);
    expect(e.mailboxPath, 'Snoozed');

    await flush();
    e = await mail();
    expect((await ops()).single.state, 'acked');
    expect(e.snoozedUntil!.isAtSameMomentAs(until), isTrue);

    await sync('Snoozed');

    e = await mail();
    expect(await ops(), isEmpty);
    expect(e.srvSnoozedUntil!.isAtSameMomentAs(until), isTrue);
    expect(e.snoozedUntil!.isAtSameMomentAs(until), isTrue);
    expect(e.localSnoozedUntil, isNull);
    await expectConsistent();
  });

  test('cancelling a queued change shows the server value again', () async {
    final id = (await mail()).id;
    final (_, captured) =
        await emails.captureOps(() => emails.setFlag(id, flagged: true));
    expect((await mail()).isFlagged, isTrue);

    expect(await emails.cancelOps(captured[id]!), hasLength(1));

    final e = await mail();
    expect(e.isFlagged, isFalse);
    expect(e.localIsFlagged, isNull);
    await expectConsistent();
  });
}
