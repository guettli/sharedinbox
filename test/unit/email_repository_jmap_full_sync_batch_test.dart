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

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';

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
  final queryPositions = <int>[];

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

  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/query') {
        observed.queryLimits.add(call.args['limit'] as int?);
        final position = (call.args['position'] as int?) ?? 0;
        observed.queryPositions.add(position);
        final limit = (call.args['limit'] as int?) ?? total;
        final end = (position + limit).clamp(0, total);
        return [
          'Email/query',
          {
            'accountId': _jmapAccountId,
            'queryState': 'q1',
            'position': position,
            'total': total,
            'ids': ids.sublist(position, end),
          },
          call.callId,
        ];
      }

      if (call.method != 'Email/get') return null;

      if (call.isBackReferenced) {
        observed.sawChainedGet = true;
        return null;
      }
      if (call.ids.isEmpty) {
        // The id-less state probe.
        observed.sawStateProbe = true;
        return jmapEmailGetResponse(
          accountId: _jmapAccountId,
          state: 'est-full',
          list: const [],
          callId: call.callId,
        );
      }

      observed.getBatchSizes.add(call.ids.length);
      return jmapEmailGetResponseFor(
        accountId: _jmapAccountId,
        state: 'est-full',
        ids: call.ids,
        mailboxId: _mailbox,
        subjectPrefix: 'full',
        omit: {if (omitFromGet != null) omitFromGet},
        callId: call.callId,
      );
    },
  );
}

void main() {
  final cacheDir = useJmapTestEnv('jmap_full_');

  test('a first sync batches its body fetches', () async {
    final observed = _Observed();
    final r = await openJmapTestRepos(
      httpClient: _fullSyncServer(observed),
      account: _jmapAccount,
      cacheDir: cacheDir(),
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
      cacheDir: cacheDir(),
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
      cacheDir: cacheDir(),
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
      contains('${_jmapAccount.id}:e1'),
      reason: 'the full sync must leave this to the guarded prune',
    );

    await r.db.close();
  });

  // #973 took a full sync of a large mailbox from ~20 requests to ~220 by
  // batching the body fetches. The state was still written only after the
  // whole run, so an interruption restarted from position 0 — the "never
  // catches up" shape of #967 again, moved from a per-request timeout to
  // total run length. A run now stops at a page boundary and the next one
  // continues from a resume key.
  group('a full sync too large for one run', () {
    // Five 500-id pages against a four-page-per-run cap.
    const big = 2300;

    Future<JmapTestRepos> open(_Observed observed) => openJmapTestRepos(
          httpClient: _fullSyncServer(observed, total: big),
          account: _jmapAccount,
          cacheDir: cacheDir(),
        );

    Future<String?> resumePoint(JmapTestRepos r) =>
        jmapStoredSyncState(r.db, 'JMAP:FullSync:$_mailbox');

    test('stops at a page boundary, then continues in the same database',
        () async {
      final observed = _Observed();
      final r = await open(observed);

      // --- first run -------------------------------------------------------
      final first = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(first.fetched, 2000, reason: 'four 500-id pages, then hand back');
      final point = await resumePoint(r);
      expect(point, isNotNull, reason: 'the next run has to know where to go');
      expect(jsonDecode(point!), {'position': 2000, 'state': 'est-full'});
      expect(
        await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
        isNull,
        reason: 'a half-paged mailbox must not look incrementally synced, or '
            'the next cycle would never fetch the rest',
      );
      expect(await jmapLocalEmailIds(r.db), hasLength(2000));

      // A row the server does not have, to prove the deferred prune runs.
      await insertJmapEmailRow(
        r.db,
        _jmapAccount.id,
        'ghost',
        mailboxPath: _mailbox,
      );
      final positionsBefore = observed.queryPositions.length;

      // --- second run, same database ---------------------------------------
      final second = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(
        observed.queryPositions[positionsBefore],
        2000,
        reason: 'resume, do not restart',
      );
      expect(second.fetched, big - 2000);
      expect(
        await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
        'est-full',
        reason: 'drained now, so the incremental path takes over',
      );
      expect(
        await resumePoint(r),
        isNull,
        reason: 'the resume point has served its purpose',
      );

      final ids = await jmapLocalEmailIds(r.db);
      // The run that finishes the mailbox has only seen its own pages, so
      // pruning to those would delete everything the earlier run fetched.
      expect(
        ids,
        hasLength(big),
        reason: 'the first run\'s 2000 messages must survive the second run',
      );
      expect(
        ids,
        contains('${_jmapAccount.id}:e0'),
        reason: 'e0 came from page one of the first run',
      );
      // Pruning is deferred to the periodic reconcile instead, which this
      // cycle runs because the resumed run left its marker unstamped.
      expect(
        ids,
        isNot(contains('${_jmapAccount.id}:ghost')),
        reason: 'a resumed run defers pruning to the reconcile, which must '
            'then actually happen',
      );

      await r.db.close();
    });

    test('a run that drains the mailbox prunes and stamps as before', () async {
      final r = await openJmapTestRepos(
        httpClient: _fullSyncServer(_Observed(), total: 3),
        account: _jmapAccount,
        cacheDir: cacheDir(),
      );

      await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(await resumePoint(r), isNull);
      expect(
        await jmapStoredSyncState(r.db, 'JMAP:Reconcile:$_mailbox'),
        isNotNull,
        reason: 'an unresumed run pruned exhaustively, so the periodic pass '
            'does not need to repeat it immediately',
      );

      await r.db.close();
    });
  });
}
