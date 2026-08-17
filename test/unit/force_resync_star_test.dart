import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// Regression tests for #558: a star (\Flagged) set locally but not yet pushed
// to the server must survive a force re-sync. The bug was that clearForResync /
// clearMailboxForResync deleted the queued `flag_flagged` pending change before
// it reached the server, so the following full re-fetch overwrote the local
// star with stale server truth and it vanished. setFlag never touches the
// network here (it enqueues + writes optimistically), so no client stub is
// needed.

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/session',
);

typedef _Repos = ({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
});

Future<_Repos> _makeRepos() async {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final emails = EmailRepositoryImpl(db, accounts);
  await accounts.addAccount(_account, 'pw');
  await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          id: 'acc-1:INBOX',
          accountId: 'acc-1',
          path: 'INBOX',
          name: 'INBOX',
          role: const Value('inbox'),
        ),
      );
  return (db: db, accounts: accounts, emails: emails);
}

/// Seeds one already-synced, unflagged message and returns its id.
Future<String> _seedEmail(_Repos r) async {
  const id = 'acc-1:INBOX:42';
  await r.db.into(r.db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          uid: 42,
          receivedAt: DateTime(2024, 6),
          subject: const Value('hello'),
          isFlagged: const Value(false),
        ),
      );
  return id;
}

Future<List<PendingChangeRow>> _pendingChanges(_Repos r) =>
    r.db.select(r.db.pendingChanges).get();

void main() {
  setUpAll(configureSqliteForTests);

  test('clearForResync preserves an un-pushed \\Flagged change (#558)',
      () async {
    final r = await _makeRepos();
    final id = await _seedEmail(r);

    await r.emails.setFlag(id, flagged: true);

    // Optimistic local star + a queued flag_flagged change.
    final email = await (r.db.select(r.db.emails)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    expect(email.isFlagged, isTrue);
    final queued = await _pendingChanges(r);
    expect(queued, hasLength(1));
    expect(queued.single.changeType, 'flag_flagged');

    await r.emails.clearForResync('acc-1');

    // The un-pushed star must NOT be dropped by the cache wipe — otherwise the
    // subsequent full re-fetch would overwrite it with stale server truth.
    final surviving = await _pendingChanges(r);
    expect(surviving, hasLength(1));
    expect(surviving.single.changeType, 'flag_flagged');

    await r.db.close();
  });

  test('clearMailboxForResync preserves an un-pushed \\Flagged change (#558)',
      () async {
    final r = await _makeRepos();
    final id = await _seedEmail(r);

    await r.emails.setFlag(id, flagged: true);
    expect(await _pendingChanges(r), hasLength(1));

    await r.emails.clearMailboxForResync('acc-1', 'INBOX');

    final surviving = await _pendingChanges(r);
    expect(surviving, hasLength(1));
    expect(surviving.single.changeType, 'flag_flagged');

    await r.db.close();
  });
}
