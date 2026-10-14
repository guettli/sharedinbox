// How the JMAP incremental sweep decides a cached message is gone.
//
// `Email/get` returns the objects it has and names every requested id it does
// not have in `notFound` (RFC 8620 §5.1). Two rules come out of that:
//
//  * Only a *disclaimed* id is deleted. Inferring it from a short response
//    read any truncated or partially-serialized reply as a deletion order.
//  * A disclaimed id whose row carries an unflushed user edit is held back,
//    so a queued change always has a row to apply to. That delays deletion
//    until `destroyed` or the periodic prune confirms it; it is not a promise
//    the message survives.
//
// The guard is wider than `_pruneJmapMailboxToServerIds`'s move/snooze
// subset, deliberately: that subset is right for a mailbox-scoped walk, where
// an optimistic move has already rewritten `mailboxPath`. This path is keyed
// by id, so what matters is only whether the user has an edit in flight — an
// unflushed star counts as much as an unflushed move.

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
  Set<String> omitSilently = const {},
  Object? rawNotFound,
  bool overrideNotFound = false,
  List<String> serverIds = const [],
  Set<String> disclaimReturned = const {},
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
      if (call.method == 'Email/query') {
        // The periodic reconcile's bare id listing. `serverIds` is what the
        // server still has, so an id left out of it is a ghost the prune
        // should clear.
        return [
          'Email/query',
          {
            'accountId': _jmapAccountId,
            'queryState': 'q1',
            'position': 0,
            'total': serverIds.length,
            'ids': serverIds,
          },
          call.callId,
        ];
      }

      if (call.method != 'Email/get') return null;
      final response = jmapEmailGetResponseFor(
        accountId: _jmapAccountId,
        state: 's1',
        ids: call.ids,
        mailboxId: _mailbox,
        omit: omit,
        omitSilently: omitSilently,
        callId: call.callId,
      );
      if (disclaimReturned.isNotEmpty) {
        // Contradictory: the same id appears in `list` *and* `notFound`.
        final args = Map<String, dynamic>.of(
          response[1] as Map<String, dynamic>,
        );
        args['notFound'] = [
          ...(args['notFound'] as List).cast<String>(),
          ...call.ids.where(disclaimReturned.contains),
        ];
        return [response[0], args, response[2]];
      }
      if (!overrideNotFound) return response;
      // Hand back whatever `rawNotFound` is, including types a compliant
      // server would never send. Copied into a dynamic-valued map because the
      // builder's literal infers `Map<String, Object>`, which rejects null.
      final args = Map<String, dynamic>.of(
        response[1] as Map<String, dynamic>,
      );
      args['notFound'] = rawNotFound;
      return [response[0], args, response[2]];
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
      _jmapAccount.id,
      'e1',
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

  test('an omitted id with a queued move keeps its row', () async {
    final r = await seeded(_server(updated: ['e1'], omit: {'e1'}));
    await queueChange(r, changeType: 'move', payload: '{"dest":"Archive"}');

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
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

    expect(
      await jmapLocalEmailIds(r.db),
      isNot(contains('${_jmapAccount.id}:e1')),
    );

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
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:e1'),
      reason: 'an unflushed star is as much a user edit as an unflushed move',
    );

    await r.db.close();
  });

  // The server omitting an id without naming it in `notFound` is not the
  // server saying it is gone. Deleting on that inference meant any short or
  // truncated response was read as a deletion order.
  test('an id omitted without being disclaimed keeps its row', () async {
    final r = await seeded(
      _server(updated: ['e1'], omitSilently: {'e1'}),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:e1'),
      reason: 'only an id named in notFound is the server saying it is gone',
    );

    await r.db.close();
  });

  // The mixed response this change exists for: one id disclaimed, another
  // dropped without being named. Both must be handled on their own terms.
  test('disclaimed and silently dropped ids in one response', () async {
    final r = await seeded(
      _server(updated: ['e1', 'e2'], omit: {'e2'}, omitSilently: {'e1'}),
    );
    await insertJmapEmailRow(
      r.db,
      _jmapAccount.id,
      'e2',
      mailboxPath: _mailbox,
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:e1'),
      reason: 'dropped without being named — not the server saying it is gone',
    );
    expect(
      await jmapLocalEmailIds(r.db),
      isNot(contains('${_jmapAccount.id}:e2')),
      reason: 'disclaimed, nothing queued against it — delete it',
    );

    await r.db.close();
  });

  // `notFound` was inert before this change, so a server sending junk in it
  // must not throw: the throw would escape before the page is checkpointed
  // and the mailbox would stall on the same page forever.
  for (final junk in <Object?>[
    null,
    'nope',
    42,
    <String, dynamic>{},
    [7],
  ]) {
    test('malformed notFound (${junk.runtimeType}) deletes nothing', () async {
      final r = await seeded(
        _server(updated: ['e1'], rawNotFound: junk, overrideNotFound: true),
      );

      await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(
        await jmapLocalEmailIds(r.db),
        contains('${_jmapAccount.id}:e1'),
        reason: 'junk must mean "delete nothing", not "throw"',
      );

      await r.db.close();
    });
  }

  // This PR's justification for keeping a row the server merely omitted is
  // that the periodic prune still clears genuine ghosts. Nothing in the repo
  // tested that: every suite stamps `JMAP:Reconcile` to keep the prune out of
  // the way, and the live-server suites all finish well inside its 15-minute
  // interval. So the safety net the argument rests on was verified nowhere.
  test('the periodic prune clears a row the sweep kept', () async {
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: _server(
        updated: ['e1'],
        omitSilently: {'e1'},
        // `serverIds` defaults to empty: the server no longer lists e1, so
        // the prune should remove it.
      ),
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
      // Past _jmapReconcileInterval, so the prune is due this cycle.
      reconcileStamp: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await insertJmapEmailRow(
      r.db,
      _jmapAccount.id,
      'e1',
      mailboxPath: _mailbox,
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      isNot(contains('${_jmapAccount.id}:e1')),
      reason: 'the sweep keeps an undisclaimed id, but the prune must still '
          'clear it — otherwise this change trades lost mail for ghosts',
    );

    await r.db.close();
  });

  // A server that both hands over an object and disclaims its id is
  // contradictory. Keeping what it handed over is the only safe reading:
  // deleting would upsert the message and then destroy it, losing mail the
  // server *did* supply — worse than the set-subtraction this replaced.
  test('an id both returned and disclaimed keeps its row', () async {
    final r = await seeded(
      _server(updated: ['e1'], disclaimReturned: {'e1'}),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:e1'),
      reason: 'the server returned the object; do not delete it on the '
          'strength of the same response also disclaiming it',
    );

    await r.db.close();
  });
}
