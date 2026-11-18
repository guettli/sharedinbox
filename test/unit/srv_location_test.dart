// Every email row records where the server has the message (schema v70,
// SYNC-REDESIGN.md phase 2a), and sync finds rows by that, never by
// building an id or by the folder a row is shown in. Row ids are opaque and
// a row keeps its id when the server moves the mail (phase 2b).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';

const _account = statefulRigAccount;

typedef _Location = (String?, int?, int?);

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() async {
    rig = await StatefulImapRig.open(
      StatefulFakeImapServer(
        uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Spam': 33},
      )
        ..deliver('INBOX', 'a@test')
        // So a mail moved to Archive gets another UID there than in INBOX.
        ..deliver('Archive', 'filler@test'),
      folders: [('INBOX', 'inbox'), ('Archive', 'archive'), ('Spam', 'junk')],
    );
  });
  tearDown(() => db.close());

  Future<List<Email>> rows() => db.select(db.emails).get();
  Future<Email> mail() async => (await rows()).single;

  /// The row of a@test once Archive (with its filler) is synced too.
  Future<Email> mailA() async =>
      (await rows()).singleWhere((e) => e.messageId != 'filler@test');
  _Location location(Email e) => (e.srvMailboxPath, e.srvUid, e.srvUidValidity);

  /// Re-reads the whole of INBOX, as after a lost checkpoint.
  Future<void> refetchInbox() async {
    await db.delete(db.syncStates).go();
    await emails.syncEmails(_account.id, 'INBOX');
  }

  /// Gives the row an id that does not name its location, as after a
  /// folder rename (only the shown path and the location follow it).
  Future<void> giveStaleId(String id) => db.customStatement(
        'UPDATE emails SET id = ?1',
        [id],
      );

  test('a fetched mail records where the server has it', () async {
    final e = await mail();
    expect(e.id, matches(RegExp(r'^acc-1:~[0-9a-f]{32}$')));
    expect(location(e), ('INBOX', 1, 11));
    expect(e.srvJmapId, isNull);
  });

  test('a refetch finds the row by its location, not by its id', () async {
    await giveStaleId('acc-1:Old:1');

    await refetchInbox();

    final e = await mail();
    expect(e.id, 'acc-1:Old:1');
    expect(location(e), ('INBOX', 1, 11));
  });

  // Not discriminating on its own: the FETCH skips a UID whose move is
  // queued (#1269) before any lookup. It pins the outcome the location
  // lookup must keep; the tests around it need the lookup.
  test('a refetch during a queued move adds no second row', () async {
    await giveStaleId('acc-1:Old:1');
    await emails.moveEmail('acc-1:Old:1', 'Archive');

    await refetchInbox();

    final e = await mail();
    expect(e.id, 'acc-1:Old:1');
    expect(e.mailboxPath, 'Archive');
    expect(location(e), ('INBOX', 1, 11));
  });

  test('a read flag set elsewhere reaches a row shown elsewhere', () async {
    // The row is shown in Archive (its move refused for good), but the
    // server still has it in INBOX: the flag refresh finds it there. Its id
    // names neither, so neither the id nor the shown folder could find it.
    await giveStaleId('acc-1:Old:1');
    await emails.moveEmail('acc-1:Old:1', 'Archive');
    await db.update(db.pendingChanges).write(
          const PendingChangesCompanion(state: Value('failed')),
        );
    await db.update(db.emails).write(
          const EmailsCompanion(mailboxPath: Value('Archive')),
        );
    server.setFlagElsewhere('a@test', r'\Seen', on: true);

    await emails.syncEmails(_account.id, 'INBOX');

    expect((await mail()).isSeen, isTrue);
  });

  test('the move remap moves the location and keeps the id', () async {
    final id = (await mail()).id;
    await emails.syncEmails(_account.id, 'Archive'); // knows its UIDVALIDITY
    await emails.moveEmail(id, 'Archive');

    await emails.flushPendingChanges(_account.id, 'pw');

    final e = await mailA();
    expect(e.id, id);
    expect(e.mailboxPath, 'Archive');
    expect(location(e), ('Archive', 2, 22));
  });

  test('behind a later queued move the location still follows the server',
      () async {
    final id = (await mail()).id;
    await emails.syncEmails(_account.id, 'Archive');
    await emails.moveEmail(id, 'Archive');
    // While the MOVE's answer is on its way the user moves the mail on;
    // that second move waits (backoff), so it is not sent in this flush.
    server.beforeAnswer = (command) async {
      if (command != 'MOVE (INBOX)') return;
      await emails.moveEmail(id, 'Spam');
      await (db.update(db.pendingChanges)
            ..where((t) => t.state.equals('pending')))
          .write(
        PendingChangesCompanion(
          state: const Value('stuck'),
          attempts: const Value(5),
          leaseUntil: Value(now.add(const Duration(hours: 1))),
        ),
      );
    };

    await emails.flushPendingChanges(_account.id, 'pw');

    final e = await mailA();
    expect(server.find('a@test')!.folder.path, 'Archive');
    expect(e.mailboxPath, 'Spam');
    expect(location(e), ('Archive', 2, 22));
  });

  test('a new mail gets a row of its own, even where an old id points',
      () async {
    // A row stored before v71 has an id that names INBOX/1, but records
    // another location: its folder was renamed INBOX → New, and a new INBOX
    // got the old name.
    await giveStaleId('acc-1:INBOX:1');
    await db.update(db.emails).write(
          const EmailsCompanion(
            mailboxPath: Value('New'),
            srvMailboxPath: Value('New'),
          ),
        );
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(
            emailId: 'acc-1:INBOX:1',
            textBody: const Value('the other mail'),
          ),
        );

    await refetchInbox();

    final all = await rows();
    final old = all.singleWhere((e) => e.id == 'acc-1:INBOX:1');
    expect(location(old), ('New', 1, 11));
    expect(old.mailboxPath, 'New');
    final fresh = all.singleWhere((e) => e.id != 'acc-1:INBOX:1');
    expect(fresh.id, startsWith('acc-1:~'));
    expect(location(fresh), ('INBOX', 1, 11));
    expect(fresh.mailboxPath, 'INBOX');
    final body = await db.select(db.emailBodies).getSingle();
    expect((body.emailId, body.textBody), ('acc-1:INBOX:1', 'the other mail'));
  });

  test('the move remap merges the copy sync stored at the destination',
      () async {
    await emails.syncEmails(_account.id, 'Archive');
    final row = await mailA();
    final id = row.id;
    final mid = row.messageId;
    // Sync already stored the moved mail at its new place, under another
    // id; and a row stored before v71 has the id that names that place.
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc-1:copy',
            accountId: 'acc-1',
            mailboxPath: 'Archive',
            uid: 2,
            receivedAt: DateTime(2024),
            messageId: Value(mid),
            srvMailboxPath: const Value('Archive'),
            srvUid: const Value(2),
            srvUidValidity: const Value(22),
          ),
        );
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc-1:Archive:2',
            accountId: 'acc-1',
            mailboxPath: 'Old',
            uid: 2,
            receivedAt: DateTime(2024),
            messageId: const Value('other@test'),
            srvMailboxPath: const Value('Old'),
            srvUid: const Value(2),
          ),
        );
    // A change the user made on the copy waits (backoff): it must survive
    // the merge, on the kept row.
    await db.into(db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: 'acc-1',
            resourceType: 'Email',
            resourceId: 'acc-1:copy',
            changeType: 'flag_flagged',
            payload: '{"uid":2,"mailboxPath":"Archive","flagged":true}',
            createdAt: now,
            state: const Value('stuck'),
            attempts: const Value(1),
            leaseUntil: Value(now.add(const Duration(hours: 1))),
          ),
        );
    // A notification shown for the copy, and a reply started to it.
    await db.into(db.notifiedEmails).insert(
          NotifiedEmailsCompanion.insert(
            accountId: 'acc-1',
            emailId: 'acc-1:copy',
            notifiedAt: now,
          ),
        );
    await db.into(db.drafts).insert(
          DraftsCompanion.insert(
            accountId: const Value('acc-1'),
            replyToEmailId: const Value('acc-1:copy'),
            updatedAt: now,
          ),
        );
    await emails.moveEmail(id, 'Archive');

    await emails.flushPendingChanges(_account.id, 'pw');

    // The move itself stays acked until a read confirms it.
    final queued = (await db.select(db.pendingChanges).get())
        .singleWhere((c) => c.state != 'acked');
    expect((queued.resourceId, queued.changeType), (id, 'flag_flagged'));
    expect(
      (await db.select(db.notifiedEmails).get()).map((n) => n.emailId),
      [id],
    );
    expect((await db.select(db.drafts).getSingle()).replyToEmailId, id);
    final byId = {for (final e in await rows()) e.id: e};
    expect(byId.keys, isNot(contains('acc-1:copy')));
    expect(location(byId[id]!), ('Archive', 2, 22));
    expect(byId[id]!.messageId, mid);
    expect(location(byId['acc-1:Archive:2']!), ('Old', 2, null));
  });

  test('Undo restores a row with its location', () async {
    final before = (await emails.getEmail((await mail()).id))!;
    await db.delete(db.emails).go();

    await emails.restoreEmails([before]);

    expect(location(await mail()), ('INBOX', 1, 11));
  });

  test(
      'Undo restores no location another row holds under another '
      'UIDVALIDITY, when the snapshot knows none', () async {
    final row = await mail();
    // A snapshot without a UIDVALIDITY (completed from an old id).
    final before = model.Email.fromJson({
      ...(await emails.getEmail(row.id))!.toJson(),
      'id': 'acc-1:old',
      'srvUidValidity': null,
    });

    await emails.restoreEmails([before]);

    final restored = (await rows()).singleWhere((e) => e.id == 'acc-1:old');
    // No UID: its folder is the one the snapshot shows it in.
    expect(location(restored), ('INBOX', null, null));
    final kept = (await rows()).singleWhere((e) => e.id == row.id);
    expect(location(kept), ('INBOX', 1, 11));
  });

  test('Undo restores no location another row holds by now', () async {
    final before = (await emails.getEmail((await mail()).id))!;
    await giveStaleId('acc-1:other');

    await emails.restoreEmails([before]);

    final restored = (await rows()).singleWhere((e) => e.id == before.id);
    // No UID: its folder is the one the snapshot shows it in.
    expect(location(restored), ('INBOX', null, null));
    final other = (await rows()).singleWhere((e) => e.id == 'acc-1:other');
    expect(location(other), ('INBOX', 1, 11));
  });
}
