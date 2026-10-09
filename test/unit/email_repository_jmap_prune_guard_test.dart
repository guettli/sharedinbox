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
}) {
  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/query') {
        final position = (call.args['position'] as int?) ?? 0;
        final limit = (call.args['limit'] as int?) ?? queryIds.length;
        final end = (position + limit).clamp(0, queryIds.length);
        final page = position >= queryIds.length
            ? const <String>[]
            : queryIds.sublist(position, end);
        return [
          'Email/query',
          {
            'accountId': _jmapAccountId,
            'queryState': 'q1',
            'position': position,
            if (!omitTotal) 'total': reportTotal ?? queryIds.length,
            'ids': page,
          },
          call.callId,
        ];
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

  Future<JmapTestRepos> withCachedRows(http.Client client) async {
    final r = await openJmapTestRepos(
      httpClient: client,
      account: _jmapAccount,
      cacheDir: cacheDir(),
    );
    for (final id in ['a', 'b', 'c']) {
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
    final r = await withCachedRows(
      _server(queryIds: const ['a', 'b', 'c'], omitTotal: true),
    );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      await jmapLocalEmailIds(r.db),
      containsAll(expectedIds(['a', 'b', 'c'])),
      reason: 'an unverifiable walk must not be pruned against',
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
