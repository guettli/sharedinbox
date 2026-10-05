// Data-loss guard for the JMAP incremental sweep.
//
// `Email/get` answers only for the ids it still has (RFC 8620 §5.1
// `notFound`), and the sweep treats an id it asked for but did not get back as
// gone. That inference is reasonable on its own, but it was acted on with none
// any guard at all, where the mailbox reconciler
// (`_pruneJmapMailboxToServerIds`) holds back rows whose optimistic edit has
// not been flushed yet.
//
// The guard here is wider than that reconciler's, deliberately: its
// move/snooze subset is right for a mailbox-scoped walk, where an optimistic
// move has already rewritten `mailboxPath`. This path is keyed by id, so what
// matters is only whether the user has an edit in flight — an unflushed star
// counts as much as an unflushed move.
//
// So: queue a move offline, have another client delete the message
// server-side, and the next sweep deletes the local row — destroying the
// user's pending edit and stranding the queued change against a row that no
// longer exists. An *explicit* `destroyed` entry is different: there the
// server is authoritative, and the deletion stands.

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

  Future<void> queueChange(
    JmapTestRepos r, {
    required String changeType,
    required String payload,
  }) async {
    await r.db.into(r.db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: _jmapAccount.id,
            // Matches what `_enqueueChange` writes, so a future
            // `resourceType` filter cannot make this fixture test nothing.
            resourceType: 'Email',
            resourceId: '${_jmapAccount.id}:e1',
            changeType: changeType,
            payload: payload,
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<Set<String>> localIds(JmapTestRepos r) async =>
      (await r.db.select(r.db.emails).get()).map((e) => e.id).toSet();

  test('an omitted id with a queued move keeps its row', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));
    await queueChange(r, changeType: 'move', payload: '{"dest":"Archive"}');

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await localIds(r),
      contains('${_jmapAccount.id}:e1'),
      reason: 'deleting here destroys the pending move and strands the '
          'queued change against a row that no longer exists',
    );

    await r.db.close();
  });

  // An explicit `destroyed` is the server being authoritative rather than
  // merely silent, so it still deletes. Keeping the row there would leave
  // mail in the list that no longer exists anywhere.
  test('an explicitly destroyed id is deleted even with a queued move',
      () async {
    final r = await seeded(_server(destroyed: ['e1']));
    await queueChange(r, changeType: 'move', payload: '{"dest":"Archive"}');

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(await localIds(r), isNot(contains('${_jmapAccount.id}:e1')));

    await r.db.close();
  });

  // The reconciler this guard was modelled on only looks for move/snooze,
  // because a move has already rewritten `mailboxPath` and that is what makes
  // a row look orphaned during a mailbox-scoped walk. Copying that subset here
  // would leave an unflushed star to be deleted — same bug, different
  // changeType.
  test('an omitted id with a queued flag edit keeps its row', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));
    await queueChange(
      r,
      changeType: 'flag_flagged',
      payload: '{"flagged":true}',
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await localIds(r),
      contains('${_jmapAccount.id}:e1'),
      reason: 'an unflushed star is as much a user edit as an unflushed move',
    );

    await r.db.close();
  });
}
