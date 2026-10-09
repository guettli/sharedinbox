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
import 'package:sharedinbox/data/db/database.dart' hide Account;

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

  /// `position` argument per `Email/query` (-1 when anchor-based, i.e. no
  /// `position` sent), so a test can assert on resume vs restart.
  final queryPositions = <int>[];

  /// `anchor` argument per `Email/query`, null when position-based.
  final queryAnchors = <String?>[];

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
  String idPrefix = 'e',
}) {
  final ids = [for (var i = 0; i < total; i++) '$idPrefix$i'];

  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/query') {
        observed.queryLimits.add(call.args['limit'] as int?);
        observed.queryPositions.add((call.args['position'] as int?) ?? -1);
        observed.queryAnchors.add(call.args['anchor'] as String?);
        return jmapQueryPage(
          accountId: _jmapAccountId,
          sortedIds: ids,
          args: call.args,
          callId: call.callId,
        );
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

  // #973 made a full sync of a large mailbox ~11x longer in requests. It still
  // loses no mail if interrupted (bodies are upserted per batch), but it used
  // to re-download the whole prefix on restart. A run now walks a bounded
  // number of pages, stores an anchor, and the next cycle continues from it.
  //
  // Resuming by a stable id rather than a numeric offset is the point: the
  // first attempt (closed #1004) paged by `position`, which skips messages
  // when mail is deleted between runs.
  group('a full sync too large for one run', () {
    // Five 500-id pages against a four-page-per-run cap.
    const big = 2300;

    Future<String?> resumePoint(JmapTestRepos r) =>
        jmapStoredSyncState(r.db, 'JMAP:FullSync:$_mailbox');

    // A second run against the same database and account, with [client] as
    // its server — the next sync cycle picking up the resume point.
    Future<JmapTestRepos> continueFrom(JmapTestRepos r, http.Client client) =>
        openJmapTestRepos(
          httpClient: client,
          account: _jmapAccount,
          cacheDir: cacheDir(),
          reuse: r,
        );

    // A first run that fills four pages and pauses at anchor e1999.
    Future<JmapTestRepos> pausedAfterFirstRun() async {
      final r = await openJmapTestRepos(
        httpClient: _fullSyncServer(_Observed(), total: big),
        account: _jmapAccount,
        cacheDir: cacheDir(),
      );
      await r.emails.syncEmails(_jmapAccount.id, _mailbox);
      return r;
    }

    test('pauses at the page cap and stores an anchor, not an offset',
        () async {
      final observed = _Observed();
      final r = await openJmapTestRepos(
        httpClient: _fullSyncServer(observed, total: big),
        account: _jmapAccount,
        cacheDir: cacheDir(),
      );

      final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(result.fetched, 2000, reason: 'four 500-id pages, then pause');
      expect(await r.db.select(r.db.emails).get(), hasLength(2000));
      expect(
        await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
        isNull,
        reason: 'a half-synced mailbox must not look incrementally synced',
      );
      final point = await resumePoint(r);
      expect(point, isNotNull);
      final decoded = jsonDecode(point!) as Map<String, dynamic>;
      expect(
        decoded['anchor'],
        'e1999',
        reason: 'the resume point is the last id fetched, a stable handle',
      );
      expect(decoded['state'], 'est-full');
      // Only the first query is position-based; the rest ride the anchor.
      expect(observed.queryPositions.first, 0);
      expect(
        observed.queryAnchors.sublist(1),
        everyElement(isNotNull),
        reason: 'pages after the first must page by anchor',
      );

      await r.db.close();
    });

    test('the next run continues from the anchor and finishes', () async {
      final r = await pausedAfterFirstRun();

      final second = _Observed();
      final r2 = await continueFrom(r, _fullSyncServer(second, total: big));

      final result = await r2.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(
        second.queryAnchors.first,
        'e1999',
        reason: 'resume from where run 1 stopped, by id',
      );
      expect(result.fetched, big - 2000);
      expect(await r.db.select(r.db.emails).get(), hasLength(big));
      expect(
        await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
        'est-full',
        reason: 'drained now, so the incremental path takes over',
      );
      expect(await resumePoint(r2), isNull);

      await r.db.close();
    });

    test('a deleted anchor restarts the walk from the top', () async {
      final r = await pausedAfterFirstRun();

      // The anchor message is gone when the next run asks for it: the server
      // now holds a different set that does not contain e1999.
      final second = _Observed();
      final r2 = await continueFrom(
        r,
        _fullSyncServer(second, total: 300, idPrefix: 'x'),
      );

      final result = await r2.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(
        second.queryAnchors.first,
        'e1999',
        reason: 'it tries the stored anchor first',
      );
      expect(
        second.queryPositions.any((p) => p == 0),
        isTrue,
        reason: 'anchorNotFound must fall back to a position-0 restart',
      );
      expect(result.fetched, 300);
      expect(await resumePoint(r2), isNull);

      await r.db.close();
    });

    // The keystone of the resumed-drain design: the final run holds only its
    // own pages, so it cannot prune — it clears the reconcile marker and the
    // periodic reconcile, running in the same cycle, prunes against a fresh
    // full walk. A ghost the resumed run never saw must still be removed, and
    // the earlier runs' messages must survive.
    test('a resumed drain defers pruning to the reconcile, which runs',
        () async {
      final r = await pausedAfterFirstRun();

      // A local row the server does not list — only a complete reconcile walk
      // can know it is gone.
      await insertJmapEmailRow(
        r.db,
        _jmapAccount.id,
        'ghost',
        mailboxPath: _mailbox,
      );

      final r2 =
          await continueFrom(r, _fullSyncServer(_Observed(), total: big));
      await r2.emails.syncEmails(_jmapAccount.id, _mailbox);

      final ids = await jmapLocalEmailIds(r.db);
      expect(
        ids,
        isNot(contains('${_jmapAccount.id}:ghost')),
        reason: 'the deferred reconcile must actually prune the ghost',
      );
      expect(
        ids,
        contains('${_jmapAccount.id}:e0'),
        reason: "run one's messages must not be pruned by the resumed drain",
      );
      expect(ids, hasLength(big));

      await r.db.close();
    });

    test('an unreadable resume point starts the walk over', () async {
      final observed = _Observed();
      final r = await openJmapTestRepos(
        httpClient: _fullSyncServer(observed, total: 3),
        account: _jmapAccount,
        cacheDir: cacheDir(),
      );
      await r.db.into(r.db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: _jmapAccount.id,
              resourceType: 'JMAP:FullSync:$_mailbox',
              state: 'not valid json {',
              syncedAt: DateTime.now(),
            ),
          );

      final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect(observed.queryPositions.first, 0, reason: 'fresh walk');
      expect(result.fetched, 3);
      expect(await resumePoint(r), isNull);

      await r.db.close();
    });

    test('a mailbox spanning three runs drains over three cycles', () async {
      const huge = 4500; // nine 500-id pages, four per run
      Future<JmapTestRepos> cycle(JmapTestRepos? prev) async {
        final client = _fullSyncServer(_Observed(), total: huge);
        return prev == null
            ? openJmapTestRepos(
                httpClient: client,
                account: _jmapAccount,
                cacheDir: cacheDir(),
              )
            : continueFrom(prev, client);
      }

      final r1 = await cycle(null);
      final a = await r1.emails.syncEmails(_jmapAccount.id, _mailbox);
      final r2 = await cycle(r1);
      final b = await r2.emails.syncEmails(_jmapAccount.id, _mailbox);
      final r3 = await cycle(r2);
      final c = await r3.emails.syncEmails(_jmapAccount.id, _mailbox);

      expect([a.fetched, b.fetched, c.fetched], [2000, 2000, 500]);
      expect(await r1.db.select(r1.db.emails).get(), hasLength(huge));
      expect(await resumePoint(r3), isNull);
      expect(
        await jmapStoredSyncState(r1.db, 'JMAP:Email:$_mailbox'),
        'est-full',
      );

      await r1.db.close();
    });
  });
}
