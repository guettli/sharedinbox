// Rows waiting for their server copy, through the real IMAP sync (the
// stateful fake server, SYNC-REDESIGN.md §6, §4.5, phase 4b): the fetch
// matches a new row with the waiting row in place, the expiries run only
// after a successful sync of the folder that could have matched, and an
// acked move whose new location is unknown carries over at once when the
// destination's copy is stored already, or gives up when the destination's
// sync finds none.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_imap_rig.dart';

const _account = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  setUp(openRigInboxArchive);
  tearDown(() => db.close());

  Future<List<PendingChangeRow>> ops() => rigOps();
  Future<void> expectConsistent() async => expect(await rigProblems(), isEmpty);
  Future<void> sync(String folder) => emails.syncEmails(_account.id, folder);

  test(
      'a note to self older than the expiry is matched by the inbox sync '
      'that stores its delivery, not dropped before it', () async {
    await EmailStateWriter(db).insertLocalRow(
      LocalRowHeaders(
        subject: 'note',
        sentAt: now.subtract(const Duration(days: 8)),
        receivedAt: now.subtract(const Duration(days: 8)),
        fromJson: '[]',
        toJson: '[]',
        ccJson: '[]',
        preview: 'note',
        hasAttachment: false,
        threadId: 'note@test',
        messageId: 'note@test',
      ),
      id: 'acc-1:~note',
      accountId: _account.id,
      mailboxPath: 'INBOX',
      keywords: const ServerKeywords(
        seen: true,
        flagged: false,
        snoozedUntil: null,
      ),
    );
    await emails.setFlag('acc-1:~note', flagged: true);
    // A flush before the sync (as each cycle runs) gives up on nothing.
    await emails.flushPendingChanges(_account.id, 'pw');
    expect((await ops()).single.state, 'parked');

    server.deliver('INBOX', 'note@test');
    await sync('INBOX');

    final rows = await (db.select(db.emails)
          ..where((t) => t.messageId.equals('note@test')))
        .get();
    expect(rows.single.id, 'acc-1:~note', reason: 'matched in place');
    expect(rows.single.isLocal, isFalse);
    expect(rows.single.isFlagged, isTrue);
    expect((await ops()).single.state, 'pending');
    await expectConsistent();
  });

  group('an acked move whose new location was not learnt', () {
    late String id;

    setUp(() async {
      id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Archive');
      final op = (await ops()).single;
      await (db.update(db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(const PendingChangesCompanion(state: Value('inflight')));
      await EmailStateWriter(db).ack(
        await (db.select(db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .getSingle(),
      );
    });

    test(
        'carries over at once when the destination synced first (no mail '
        'shown twice)', () async {
      server.moveElsewhere('a@test', 'Archive');
      await sync('Archive');
      expect(await rowsOfA(), hasLength(2), reason: 'stored again, for now');

      await sync('INBOX');

      final row = (await rowsOfA()).single;
      expect(row.id, id);
      expect(row.srvMailboxPath, 'Archive');
      expect(row.srvGone, isFalse);
      expect(row.mailboxPath, 'Archive');
      expect(await ops(), isEmpty, reason: 'the move is confirmed');
      await expectConsistent();
    });

    test('gives up when the destination sync finds no copy', () async {
      // Another client moved it on from Archive to INBOX's sibling: it is
      // gone from INBOX, and Archive will not have it.
      server.expungeElsewhere('a@test');
      await sync('INBOX');
      expect((await rowOfA()).mailboxPath, 'Archive', reason: 'waiting');

      await sync('Archive');

      expect(await rowsOfA(), isEmpty, reason: 'hidden, then cleaned up');
      expect(await ops(), isEmpty);
    });
  });
}
