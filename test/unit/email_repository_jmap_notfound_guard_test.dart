// Data-loss guard for the JMAP incremental sweep.
//
// `Email/get` answers only for the ids it still has (RFC 8620 §5.1
// `notFound`), and the sweep treats an id it asked for but did not get back as
// gone. That inference is reasonable on its own, but it was acted on with none
// of the guards the mailbox reconciler carries:
//
//   `_pruneJmapMailboxToServerIds` skips rows whose optimistic move or snooze
//   has not been flushed yet, and skips local self-sent "virtual" rows (#545).
//
// So: queue a move offline, have another client delete the message
// server-side, and the next sweep deletes the local row — destroying the
// user's pending edit and stranding the queued change against a row that no
// longer exists. An *explicit* `destroyed` entry is different: there the
// server is authoritative, and the deletion stands.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

const _jmapAccount = Account(
  id: 'jmap-nf',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// A server that reports [updated] as changed, then omits [omit] from the
/// `Email/get` that follows — or reports [destroyed] as explicitly gone.
http.Client _server({
  List<String> updated = const [],
  List<String> destroyed = const [],
  Set<String> omit = const {},
}) {
  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/changes') {
        return [
          'Email/changes',
          {
            'accountId': _jmapAccountId,
            'oldState': 's0',
            'newState': 's1',
            'hasMoreChanges': false,
            'created': <String>[],
            'updated': updated,
            'destroyed': destroyed,
          },
          call.callId,
        ];
      }
      if (call.method != 'Email/get') return null;
      return jmapEmailGetResponseFor(
        accountId: _jmapAccountId,
        state: 's1',
        ids: call.ids,
        mailboxId: _mailbox,
        omit: omit,
        callId: call.callId,
      );
    },
  );
}

void main() {
  final cacheDir = useJmapTestEnv('jmap_nf_');

  Future<JmapTestRepos> seeded(http.Client client) async {
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: client,
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
    );
    await insertJmapEmailRow(
      r.db,
      accountId: _jmapAccount.id,
      jmapId: 'e1',
      mailboxPath: _mailbox,
    );
    return r;
  }

  Future<void> queueMove(JmapTestRepos r) async {
    await r.db.into(r.db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: _jmapAccount.id,
            resourceType: 'email',
            resourceId: '${_jmapAccount.id}:e1',
            changeType: 'move',
            payload: '{"dest":"Archive"}',
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<Set<String>> localIds(JmapTestRepos r) async =>
      (await r.db.select(r.db.emails).get()).map((e) => e.id).toSet();

  test('an omitted id with a queued move keeps its row', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));
    await queueMove(r);

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await localIds(r),
      contains('${_jmapAccount.id}:e1'),
      reason: 'deleting here destroys the pending move and strands the '
          'queued change against a row that no longer exists',
    );
    expect(
      await r.db.select(r.db.pendingChanges).get(),
      hasLength(1),
      reason: 'the queued change must still have something to apply to',
    );

    await r.db.close();
  });

  test('an omitted id with nothing queued is still cleaned up', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await localIds(r),
      isNot(contains('${_jmapAccount.id}:e1')),
      reason: 'the guard must not turn into "never delete" — a stale row with '
          'no pending edit should still go',
    );

    await r.db.close();
  });

  // An explicit `destroyed` is the server being authoritative rather than
  // merely silent, so it still deletes. Keeping the row there would leave
  // mail in the list that no longer exists anywhere.
  test('an explicitly destroyed id is deleted even with a queued move',
      () async {
    final r = await seeded(_server(destroyed: ['e1']));
    await queueMove(r);

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(await localIds(r), isNot(contains('${_jmapAccount.id}:e1')));

    await r.db.close();
  });

  test('a local self-sent row is never deleted on an omission', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));
    await (r.db.update(r.db.emails)
          ..where((t) => t.id.equals('${_jmapAccount.id}:e1')))
        .write(const EmailsCompanion(isLocal: Value(true)));

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await localIds(r),
      contains('${_jmapAccount.id}:e1'),
      reason: 'a virtual self-sent row has no server counterpart and must '
          'survive until the real message arrives (#545)',
    );

    await r.db.close();
  });
}
