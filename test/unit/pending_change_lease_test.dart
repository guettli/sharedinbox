// A flush claims a queued change as `inflight` with a lease (SYNC.md §6):
// what that claim protects, and what happens when its flush dies.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

void main() {
  setUpAll(configureSqliteForTests);

  late StatefulFakeImapServer server;
  late AppDatabase db;
  late EmailRepositoryImpl emails;
  var now = DateTime.utc(2026, 11, 16, 12);

  setUp(() async {
    now = DateTime.utc(2026, 11, 16, 12);
    server = StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 11})
      ..deliver('INBOX', 'a@test');
    db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
    emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: (_, __, ___) async => server.connect(),
      smtpConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no SMTP in this test')),
      fetchObjectIds: (_, __, ___) async => const {},
      fetchPreviewSnippets: (_, __, ___) async => const {},
      now: () => now,
    );
    await accounts.addAccount(_account, 'pw');
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '${_account.id}:INBOX',
            accountId: _account.id,
            path: 'INBOX',
            name: 'INBOX',
            role: const Value('inbox'),
          ),
        );
    await emails.syncEmails(_account.id, 'INBOX');
  });
  tearDown(() => db.close());

  Future<Email> mail() async => (await db.select(db.emails).get()).single;
  Future<PendingChangeRow> change() async =>
      (await db.select(db.pendingChanges).get()).single;

  /// As if a flush claimed the queued change and is sending it, its lease
  /// running until [leaseUntil].
  Future<void> claimAsAnotherFlush(DateTime leaseUntil) =>
      db.update(db.pendingChanges).write(
            PendingChangesCompanion(
              state: const Value('inflight'),
              leaseUntil: Value(leaseUntil),
            ),
          );

  test('a change claimed by another flush is left to it', () async {
    await emails.setFlag((await mail()).id, seen: true);
    await claimAsAnotherFlush(now.add(const Duration(minutes: 5)));

    expect(await emails.flushPendingChanges(_account.id, 'pw'), 0);

    expect(server.find('a@test')!.message.seen, isFalse);
    final c = await change();
    expect(c.state, 'inflight');
    expect(c.attempts, 0);
  });

  test('an in-flight change still protects its value from sync', () async {
    await emails.setFlag((await mail()).id, seen: true);
    await claimAsAnotherFlush(now.add(const Duration(minutes: 5)));
    // A full flag read of the folder: the server still says unread.
    await db.delete(db.syncStates).go();

    await emails.syncEmails(_account.id, 'INBOX');

    expect((await mail()).isSeen, isTrue);
  });

  test('Undo cannot cancel an in-flight change', () async {
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    await claimAsAnotherFlush(now.add(const Duration(minutes: 5)));

    expect(await emails.cancelPendingChange(id, 'flag_seen'), isFalse);
    expect(await db.select(db.pendingChanges).get(), isNotEmpty);
  });

  test('a change whose flush died is charged an attempt and sent again',
      () async {
    await emails.setFlag((await mail()).id, seen: true);
    await claimAsAnotherFlush(now.subtract(const Duration(seconds: 1)));

    expect(await emails.flushPendingChanges(_account.id, 'pw'), 1);

    expect(server.find('a@test')!.message.seen, isTrue);
    expect(await db.select(db.pendingChanges).get(), isEmpty);
  });

  test('a change whose flush died at the retry limit is sent once more',
      () async {
    await emails.setFlag((await mail()).id, seen: true);
    await db.update(db.pendingChanges).write(
          const PendingChangesCompanion(attempts: Value(4)),
        );
    await claimAsAnotherFlush(now.subtract(const Duration(seconds: 1)));

    // It probably reached the server: not given up on unseen.
    expect(await emails.flushPendingChanges(_account.id, 'pw'), 1);

    expect(server.find('a@test')!.message.seen, isTrue);
    expect(await db.select(db.pendingChanges).get(), isEmpty);
  });

  test('a flush leaves the other changes of a mail being sent elsewhere',
      () async {
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    await claimAsAnotherFlush(now.add(const Duration(minutes: 5)));
    await emails.setFlag(id, flagged: true);
    server.deliver('INBOX', 'b@test');
    await emails.syncEmails(_account.id, 'INBOX');
    final b = (await db.select(db.emails).get())
        .singleWhere((e) => e.messageId == 'b@test');
    await emails.setFlag(b.id, flagged: true);

    expect(await emails.flushPendingChanges(_account.id, 'pw'), 1);

    expect(server.find('b@test')!.message.flagged, isTrue);
    // a's star waits behind its read change, still claimed elsewhere.
    expect(server.find('a@test')!.message.flagged, isFalse);
    final left = await (db.select(db.pendingChanges)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    expect(
      [for (final c in left) '${c.changeType} ${c.state} ${c.attempts}'],
      ['flag_seen inflight 0', 'flag_flagged pending 0'],
    );
    expect(
      left.first.leaseUntil!
          .isAtSameMomentAs(now.add(const Duration(minutes: 5))),
      isTrue,
    );
  });

  test('a flush that lost its claim leaves the new claim alone', () async {
    await emails.setFlag((await mail()).id, seen: true);
    server.beforeAnswer = (command) async {
      if (command.startsWith('STORE')) {
        // Meanwhile this flush's lease ran out and another flush took the
        // change over; then this flush's STORE fails.
        await db.update(db.pendingChanges).write(
              PendingChangesCompanion(
                claimToken: const Value('other-flush'),
                leaseUntil: Value(now.add(const Duration(minutes: 5))),
              ),
            );
        throw StateError('answer lost');
      }
    };

    await emails.flushPendingChanges(_account.id, 'pw');

    final c = await change();
    expect(c.state, 'inflight');
    expect(c.claimToken, 'other-flush');
    expect(c.attempts, 0);
  });

  test('a flush settles every change it claims', () async {
    final id = (await mail()).id;
    await emails.setFlag(id, seen: true);
    server.refuses = (messageId) => true;

    await emails.flushPendingChanges(_account.id, 'pw');

    final c = await change();
    expect(c.state, 'pending');
    expect(c.leaseUntil, isNull);
    expect(c.attempts, 1);
  });
}
