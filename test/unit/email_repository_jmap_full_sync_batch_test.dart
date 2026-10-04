// The other half of issue #967.
//
// #968 bounded the incremental sweep's `Email/get` at 50 ids, because one
// request for an unbounded id list *plus* full HTML and text body values makes
// the server serialize every message before it can answer — which blew past the
// client's request timeout and reported itself as a network failure.
//
// The full-sync path had the same shape and was left alone at the time: its
// `Email/query` chained `Email/get` straight onto its own result, asking for up
// to `_jmapPageSize` (500) full bodies in a single request — ten times the
// batch the incremental path settled on. That path is taken by a mailbox's
// first-ever sync, by `forceResync`, and by the `cannotCalculateChanges`
// fallback.
//
// Removing the chained fetch moved where the sync checkpoint comes from: it
// used to be read off that first `Email/get`'s `state`. It is now captured by
// an `Email/get` with an empty `ids` list, which returns the state and nothing
// else — and, unlike a body fetch, still returns one for an empty mailbox.
// Verified against Stalwart 0.14.1: that state advances with the mailbox, is
// accepted as an `Email/changes` sinceState, and is identical to the state a
// body-fetching `Email/get` reports.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'db_test_helper.dart';
import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

/// One full `Email/query` page (500) plus a short one, so a single sweep has
/// to page the query *and* batch each page's body fetches.
const _total = 620;

/// The client's own bounds, asserted absolutely.
const _queryPageBound = 500;
const _getBatchBound = 50;

const _jmapAccount = Account(
  id: 'jmap-full',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

class _Observed {
  final getBatchSizes = <int>[];
  final queryLimits = <int?>[];

  /// True when a request chained `Email/get` onto an `Email/query` result
  /// instead of asking for ids it had already received — the shape that made
  /// one request answer for a whole page of bodies.
  var sawChainedGet = false;

  /// Whether the client asked for the state with an id-less `Email/get`.
  var sawStateProbe = false;
}

/// [omitFromGet] makes `Email/get` leave an id out of its `list` even though
/// `Email/query` listed it — the shape that decides whether a full sync
/// deletes the local row or leaves it to the guarded prune.
http.Client _fullSyncServer(
  _Observed observed, {
  int total = _total,
  String? omitFromGet,
}) {
  final ids = [for (var i = 0; i < total; i++) 'e$i'];

  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return jmapSessionResponse(accountId: _jmapAccountId);
    }

    final methodResponses = <List<dynamic>>[];
    for (final call in jmapMethodCalls(req)) {
      final method = call[0] as String;
      final args = call[1] as Map<String, dynamic>;
      final callId = call[2];

      if (method == 'Email/query') {
        observed.queryLimits.add(args['limit'] as int?);
        final position = (args['position'] as int?) ?? 0;
        final limit = (args['limit'] as int?) ?? total;
        final end = (position + limit).clamp(0, total);
        methodResponses.add([
          'Email/query',
          {
            'accountId': _jmapAccountId,
            'queryState': 'q1',
            'position': position,
            'total': total,
            'ids': ids.sublist(position, end),
          },
          callId,
        ]);
        continue;
      }

      if (method == 'Email/get') {
        if (args.containsKey('#ids')) observed.sawChainedGet = true;
        final requested =
            ((args['ids'] as List<dynamic>?) ?? const []).cast<String>();
        if (requested.isEmpty && !args.containsKey('#ids')) {
          // The id-less state probe.
          observed.sawStateProbe = true;
          methodResponses.add(
            jmapEmailGetResponse(
              accountId: _jmapAccountId,
              state: 'est-full',
              list: const [],
              callId: callId,
            ),
          );
          continue;
        }
        observed.getBatchSizes.add(requested.length);
        methodResponses.add(
          jmapEmailGetResponse(
            accountId: _jmapAccountId,
            state: 'est-full',
            list: [
              for (final id in requested)
                if (id != omitFromGet)
                  jmapEmailObject(
                    id: id,
                    mailboxId: _mailbox,
                    subject: 'full $id',
                  ),
            ],
            callId: callId,
          ),
        );
        continue;
      }

      methodResponses.add([
        'error',
        {'type': 'unknownMethod'},
        callId,
      ]);
    }

    return jmapApiResponse(methodResponses);
  });
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory cacheDir;
  setUp(() => cacheDir = Directory.systemTemp.createTempSync('jmap_full_'));
  tearDown(() => cacheDir.deleteSync(recursive: true));

  test('a first sync batches its body fetches', () async {
    final observed = _Observed();
    final r = await openJmapTestRepos(
      httpClient: _fullSyncServer(observed),
      account: _jmapAccount,
      cacheDir: cacheDir,
    );

    // No stored state → the full-sync path.
    final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(result.fetched, _total);
    expect(await r.db.select(r.db.emails).get(), hasLength(_total));

    expect(
      observed.sawChainedGet,
      isFalse,
      reason: 'chaining Email/get onto the query makes one request answer for '
          'a whole page of bodies — the shape that timed out in #967',
    );
    expect(
      observed.getBatchSizes,
      everyElement(lessThanOrEqualTo(_getBatchBound)),
      reason: 'a body fetch must be capped regardless of the query page size',
    );
    expect(
      observed.queryLimits,
      everyElement(lessThanOrEqualTo(_queryPageBound)),
    );
    expect(
      observed.queryLimits.length,
      2,
      reason: '620 emails is one full 500-id query page plus a short one',
    );
    expect(
      observed.getBatchSizes.length,
      13,
      reason: '500 ids in batches of 50, then 120 in three more',
    );
    expect(await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'), 'est-full');

    await r.db.close();
  });

  // The chained fetch was also where the checkpoint came from, so removing it
  // had to not break the one case that fetches nothing at all.
  test('an empty mailbox still records a checkpoint', () async {
    final observed = _Observed();
    final r = await openJmapTestRepos(
      httpClient: _fullSyncServer(observed, total: 0),
      account: _jmapAccount,
      cacheDir: cacheDir,
    );

    final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(result.fetched, 0);
    expect(observed.getBatchSizes, isEmpty, reason: 'nothing to fetch');
    expect(
      observed.sawStateProbe,
      isTrue,
      reason: 'the state has to come from somewhere when no body is fetched',
    );
    expect(
      await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
      'est-full',
      reason: 'without a checkpoint the next cycle would full-sync again',
    );

    await r.db.close();
  });

  // A full sync must not delete on its own. Its reconciler is
  // `_pruneJmapMailboxToServerIds`, which keeps everything `Email/query`
  // listed and — unlike a bare delete — skips local-only rows (#545) and rows
  // carrying an unflushed optimistic move or snooze. Batching the body fetches
  // brought a delete-the-ids-`Email/get`-omitted step along with it from the
  // incremental path; letting that run here would pre-empt the prune with
  // neither guard.
  test('does not delete a row for an id Email/get omits', () async {
    final observed = _Observed();
    final r = await openJmapTestRepos(
      httpClient: _fullSyncServer(observed, total: 3, omitFromGet: 'e1'),
      account: _jmapAccount,
      cacheDir: cacheDir,
    );
    // A row with an unflushed move queued against it — exactly what the
    // prune's in-flight guard exists to protect.
    await r.db.into(r.db.emails).insert(
          EmailsCompanion.insert(
            id: '${_jmapAccount.id}:e1',
            accountId: _jmapAccount.id,
            mailboxPath: _mailbox,
            uid: 0,
            receivedAt: DateTime(2026),
          ),
        );

    await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    final ids = (await r.db.select(r.db.emails).get()).map((e) => e.id).toSet();
    expect(
      ids,
      contains('${_jmapAccount.id}:e1'),
      reason: 'the full sync must leave this to the guarded prune',
    );

    await r.db.close();
  });
}
