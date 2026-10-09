// A spurious `Email/query` response must not wipe a folder.
//
// Both JMAP prunes — the end of a full sync, and the 15-minutely reconcile —
// walked the mailbox with `Email/query` and then deleted every local row whose
// id the walk had not seen. Neither checked that the walk had actually
// enumerated anything:
//
//   if (ids.isEmpty || total == null || position >= total) break;
//
// So one empty page meant an empty `seenIds`, and the prune that followed
// deleted every non-local, non-in-flight row in the folder. An absent `total`
// was worse than it looks: the walk stopped after the first page, so a server
// that ignores `calculateTotal` had its mailbox truncated to 500 messages and
// then pruned down to them.
//
// A prune now requires the server to have said how many messages there are and
// the walk to have collected that many.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

const _jmapAccount = Account(
  id: 'jmap-prune',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// A server whose `Email/query` answers can be made inconsistent:
/// [queryIds] is what it lists, [reportTotal] what it claims is there.
http.Client _server({
  required List<String> queryIds,
  int? reportTotal,
  bool omitTotal = false,
  bool ignorePosition = false,
}) {
  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/changes') {
        // Nothing changed; the point of these tests is the prune that the
        // reconcile does afterwards, not the sweep.
        return [
          'Email/changes',
          {
            'accountId': _jmapAccountId,
            'oldState': 's0',
            'newState': 's0',
            'hasMoreChanges': false,
            'created': <String>[],
            'updated': <String>[],
            'destroyed': <String>[],
          },
          call.callId,
        ];
      }
      if (call.method == 'Email/query') {
        if (ignorePosition) {
          // A server that honours neither `position` nor `anchor` hands back
          // the same first page forever.
          final limit = (call.args['limit'] as int?) ?? queryIds.length;
          return [
            'Email/query',
            {
              'accountId': _jmapAccountId,
              'queryState': 'q1',
              'position': 0,
              if (!omitTotal) 'total': reportTotal ?? queryIds.length,
              'ids': queryIds.sublist(0, limit.clamp(0, queryIds.length)),
            },
            call.callId,
          ];
        }
        return jmapQueryPage(
          accountId: _jmapAccountId,
          sortedIds: queryIds,
          args: call.args,
          callId: call.callId,
          total: reportTotal,
          omitTotal: omitTotal,
        );
      }
      if (call.method != 'Email/get') return null;
      if (call.ids.isEmpty) {
        return jmapEmailGetResponse(
          accountId: _jmapAccountId,
          state: 'est1',
          list: const [],
          callId: call.callId,
        );
      }
      return jmapEmailGetResponseFor(
        accountId: _jmapAccountId,
        state: 'est1',
        ids: call.ids,
        mailboxId: _mailbox,
        callId: call.callId,
      );
    },
  );
}

void main() {
  final cacheDir = useJmapTestEnv('jmap_prune_');

  Future<JmapTestRepos> withCachedRows(
    http.Client client, {
    List<String> extra = const [],
  }) async {
    final r = await openJmapTestRepos(
      httpClient: client,
      account: _jmapAccount,
      cacheDir: cacheDir(),
    );
    for (final id in ['a', 'b', 'c', ...extra]) {
      await insertJmapEmailRow(
        r.db,
        _jmapAccount.id,
        id,
        mailboxPath: _mailbox,
      );
    }
    return r;
  }

  Set<String> expectedIds(Iterable<String> jmapIds) =>
      {for (final id in jmapIds) '${_jmapAccount.id}:$id'};

  test('an empty page while the server still reports mail keeps the rows',
      () async {
    // The folder has three messages per `total`, but the query hands back
    // nothing — a response we cannot act on.
    final r = await withCachedRows(
      _server(queryIds: const [], reportTotal: 3),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      expectedIds(['a', 'b', 'c']),
      reason: 'one bad Email/query must not cost the whole folder',
    );

    await r.db.close();
  });

  test('a server that never reports a total keeps the rows', () async {
    // `d` is cached but not listed by the server, so it is the only row a
    // prune could remove — without it this test passes whether or not the
    // gate exists.
    final r = await withCachedRows(
      _server(queryIds: const ['a', 'b', 'c'], omitTotal: true),
      extra: const ['d'],
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:d'),
      reason: 'an unverifiable walk must not be pruned against',
    );

    await r.db.close();
  });

  // The count has to match exactly. A `total` smaller than what the walk
  // collected used to wave it through: the walk ends after the first page and
  // `500 >= 0` authorised pruning the rest of the folder away.
  test('a total smaller than the page the server returned keeps the rows',
      () async {
    final r = await withCachedRows(
      _server(queryIds: const ['a', 'b', 'c'], reportTotal: 0),
      extra: const ['d'],
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      contains('${_jmapAccount.id}:d'),
      reason: 'total: 0 alongside a non-empty page is not a count we can act '
          'on',
    );

    await r.db.close();
  });

  // The periodic reconcile is the dangerous one — it runs on every mailbox,
  // so one bad Email/query was enough to empty a folder. The full sync only
  // runs on a first sync or a force resync.
  test('the periodic reconcile also refuses to prune on a bad walk', () async {
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: _server(queryIds: const [], reportTotal: 3),
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
      // Past the 15-minute interval, so the reconcile is due this cycle.
      reconcileStamp: DateTime.now().subtract(const Duration(hours: 1)),
    );
    for (final id in ['a', 'b', 'c']) {
      await insertJmapEmailRow(
        r.db,
        _jmapAccount.id,
        id,
        mailboxPath: _mailbox,
      );
    }

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      expectedIds(['a', 'b', 'c']),
      reason: 'the reconcile prunes on every mailbox every 15 minutes; one '
          'empty response must not cost a folder',
    );

    await r.db.close();
  });

  // A walk the server truncates must not checkpoint the Email state. Doing so
  // switches the mailbox to the incremental path, and `Email/changes` only
  // reports what happened after that state — so everything the walk never
  // reached becomes unreachable by any path.
  test('a stalled walk does not checkpoint the mailbox as synced', () async {
    final r = await openJmapTestRepos(
      httpClient: _server(
        queryIds: [for (var i = 0; i < 600; i++) 'm$i'],
        ignorePosition: true,
      ),
      account: _jmapAccount,
      cacheDir: cacheDir(),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
      isNull,
      reason: 'checkpointing a truncated walk strands the rest of the mailbox '
          'on a path that can never fetch it',
    );

    await r.db.close();
  });

  // The absent-`total` case was two bugs, not one. Besides skipping the prune,
  // the old walk *stopped* when `total` was missing — so a server that ignores
  // `calculateTotal` had its mailbox silently truncated to the first page.
  test('a server that never reports a total is still paged to the end',
      () async {
    const count = 600; // more than one 500-id page
    final ids = [for (var i = 0; i < count; i++) 'm$i'];
    final r = await openJmapTestRepos(
      httpClient: _server(queryIds: ids, omitTotal: true),
      account: _jmapAccount,
      cacheDir: cacheDir(),
    );

    final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      result.fetched,
      count,
      reason: 'stopping on a missing total truncated the mailbox to 500',
    );
    expect(await jmapLocalEmailIds(r.db), hasLength(count));

    await r.db.close();
  });

  test('a genuinely empty mailbox still has its leftovers pruned', () async {
    // total: 0 and nothing listed agree with each other, so the walk is
    // complete and the stale rows should go.
    final r = await withCachedRows(
      _server(queryIds: const [], reportTotal: 0),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      isEmpty,
      reason: 'the guard must not turn into "never prune"',
    );

    await r.db.close();
  });

  test('a complete walk still prunes what the server no longer lists',
      () async {
    // The server lists a and b; c is gone.
    final r = await withCachedRows(
      _server(queryIds: const ['a', 'b'], reportTotal: 2),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    final ids = await jmapLocalEmailIds(r.db);
    expect(ids, containsAll(expectedIds(['a', 'b'])));
    expect(
      ids,
      isNot(contains('${_jmapAccount.id}:c')),
      reason: 'a trustworthy walk must still prune',
    );

    await r.db.close();
  });
}
