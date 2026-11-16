part of '../email_repository_impl.dart';

// JMAP sync: full and incremental email sync, upsert, prune and flag
// reconcile, sync state.

// ── JMAP email sync ────────────────────────────────────────────────────────

const _jmapPageSize = 500;

/// Backstop on an `Email/query` walk. Set far above any real mailbox
/// (2 000 pages = 1 000 000 messages) because it is not the mechanism that
/// catches a misbehaving server — a walk that stops making progress is, and
/// that trips after two pages rather than two thousand.
///
/// Reaching this means the enumeration is incomplete, so nothing is pruned
/// and — in the full sync — no state is checkpointed, because checkpointing
/// a truncated walk would switch the mailbox to the incremental path with
/// its older messages never downloaded.
const _jmapMaxQueryPages = 2000;

/// Whether a walk that collected [seen] ids, with [reportedTotal] being the
/// last `total` the server gave, can be trusted to have enumerated the whole
/// mailbox.
///
/// This gates every prune, because pruning against an untrustworthy
/// enumeration deletes every message the walk did not see — and for a
/// spurious empty first page that is the entire mailbox. A server that
/// answers one bad `Email/query` should cost a deferred reconcile, not a
/// folder.
///
/// An empty mailbox reports `total: 0` and collects nothing, which is
/// complete and correctly prunes away local leftovers. A server that does
/// not report `total` at all is never trusted; the periodic reconcile
/// retries instead.
///
/// Exact equality, not `>=`. A `total` that is too small would otherwise
/// wave the walk through: `total: 0` alongside a full page of ids ends the
/// walk after that page, and `500 >= 0` would authorise pruning the rest of
/// the folder away. Equality also rejects the case where the mailbox shrank
/// mid-walk — position paging shifts backwards, so ids get skipped while the
/// count still lines up, and `seen` would be missing messages that are
/// still on the server. This is a count check, not an integrity check; it
/// only has to be conservative.
bool _jmapEnumerationComplete(Set<String> seen, int? reportedTotal) =>
    reportedTotal != null && seen.length == reportedTotal;

const _emailProperties = [
  'id',
  'threadId',
  'mailboxIds',
  'subject',
  // Raw Subject header so we can re-decode client-side when the server's
  // RFC 2047 decoding leaves stray spaces around encoded-word boundaries
  // (see #418, and [decodeMailHeader]).
  'header:Subject:asRaw',
  'sentAt',
  'receivedAt',
  'from',
  'to',
  'cc',
  'replyTo',
  'bcc',
  'size',
  'keywords',
  'hasAttachment',
  'preview',
  'messageId',
  'inReplyTo',
  'references',
  'textBody',
  'htmlBody',
  'bodyValues',
  'attachments',
  'header:List-Unsubscribe:asText',
];

const _emailGetBodyOptions = {
  'fetchHTMLBodyValues': true,
  'fetchTextBodyValues': true,
};

/// How many `Email/query` pages one full-sync invocation walks before it
/// pauses and hands back, so the next cycle continues from the resume point.
///
/// #973 split the chained body fetch into bounded batches, taking a
/// 10 000-mail mailbox from ~20 requests to ~220. Running all of that in one
/// invocation and losing it to a backgrounded app or a dropped connection
/// would be the "never catches up" shape of #967 again, moved from a
/// per-request timeout to total run length.
const _jmapFullSyncPagesPerRun = 4;

/// Where an unfinished full sync stores its resume point.
///
/// Deliberately NOT `JMAP:Email:<mailbox>`: that key means "incrementally
/// synced", and writing it mid-sync would send the next cycle to
/// `Email/changes`, which never fetches the mailbox's remaining pages.
String _jmapFullSyncKey(String mailboxJmapId) => 'JMAP:FullSync:$mailboxJmapId';

/// Upper bound on how many ids `Email/changes` may report per request
/// (RFC 8620 §5.2 `maxChanges`). Without it a long-dormant mailbox hands
/// back its entire backlog in one response, which then has to be fetched in
/// one `Email/get` — see [_jmapGetBatchSize].
const _jmapMaxChanges = 200;

/// Upper bound on how many ids go into a single `Email/get`.
///
/// The incremental sweep asks for full bodies (`fetchHTMLBodyValues` /
/// `fetchTextBodyValues`) plus attachment metadata, so one request for an
/// unbounded id list makes the server serialize every body before it can
/// answer. That blows past the client's request timeout, the cycle dies with
/// a misleading "could not reach the mail server", and because no state is
/// checkpointed the next cycle asks for the same oversized page again — the
/// account never catches up (issue #967).
const _jmapGetBatchSize = 50;

/// How many `Email/changes` pages one `syncEmails` call will drain.
///
/// Checkpointing per page means stopping early costs nothing — the next
/// cycle resumes from the stored token — so a huge backlog is drained over
/// several cycles instead of one run long enough for a background job to be
/// killed in the middle of. Also bounds the loop against a server that
/// hands out a fresh token on every page while never clearing
/// `hasMoreChanges`.
const _jmapMaxPagesPerSync = 20;

const _jmapReconcileInterval = Duration(minutes: 15);

extension _SyncJmap on EmailRepositoryImpl {
  Future<model.SyncEmailsResult> _syncEmailsJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxResourceType = 'JMAP:Email:$mailboxJmapId';
    var storedMailboxState =
        await _loadSyncState(account.id, mailboxResourceType);

    // A full sync that paused part-way leaves no `JMAP:Email:` state but does
    // leave a resume point. It MUST stay on the full-sync path: taking the
    // incremental path here would ask `Email/changes` for deltas and never
    // fetch the mailbox's remaining pages. Checked before the global-state
    // fallback, which would otherwise adopt another mailbox's state and send
    // this one incremental (the defect that sank the first resume attempt).
    final resuming =
        await _loadSyncState(account.id, _jmapFullSyncKey(mailboxJmapId)) !=
            null;

    if (storedMailboxState == null && !resuming) {
      // Fallback to global 'Email' state
      final globalState = await _loadSyncState(account.id, 'Email');
      if (globalState != null) {
        storedMailboxState = globalState;
        await _saveSyncState(account.id, mailboxResourceType, globalState);
      }
    }

    try {
      if (resuming || storedMailboxState == null) {
        log(
          'JMAP-sync: full sync mailbox=$mailboxJmapId '
          '(${resuming ? 'resuming' : 'no stored state'})',
        );
        return await _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
      }
      log(
        'JMAP-sync: incremental sync mailbox=$mailboxJmapId '
        'sinceState=$storedMailboxState',
      );
      return await _jmapIncrementalEmailSync(
        account.id,
        jmap,
        storedMailboxState,
        mailboxJmapId: mailboxJmapId,
      );
    } finally {
      // Defence-in-depth: periodically diff the local cache against a bare
      // Email/query to catch server-side edge cases where Email/changes
      // under-reports deletions (see #262). Cheap: ids only, no bodies.
      //
      // In a `finally` because this is the only cleanup that ever reaches a
      // row the server silently omitted — `Email/changes` will not re-report
      // it once the page is checkpointed. Sequenced after the sync, a folder
      // that throws every cycle (`_syncFolders` catches per folder and moves
      // on) would never be reconciled at all, and its ghosts would be
      // permanent.
      //
      // Its own failure must not replace the sync's: a throw out of a
      // `finally` discards the exception in flight.
      try {
        await _maybeReconcileJmapMailbox(account.id, jmap, mailboxJmapId);
      } catch (e, stack) {
        log(
          'JMAP-sync: reconcile failed for mailbox=$mailboxJmapId',
          error: e,
          stackTrace: stack,
        );
      }
    }
  }

  Future<model.SyncEmailsResult> _jmapFullEmailSync(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    final resumeKey = _jmapFullSyncKey(mailboxJmapId);

    // Resume point: the id of the last message fetched (the paging anchor) and
    // the Email state token captured on the very first page. Resuming by a
    // stable id rather than a numeric `position` is the whole reason this is a
    // second attempt: `Email/query` offsets shift when mail is added or
    // removed between runs, so a position-based resume silently skipped
    // messages. An anchor is immune to changes above it, and when the anchor
    // message itself is deleted the server answers `anchorNotFound` and the
    // walk restarts from the top — mbsync's UIDVALIDITY reset, in JMAP terms.
    String? anchor;
    String? state;
    final stored = await _loadSyncState(accountId, resumeKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as Map<String, dynamic>;
        final a = decoded['anchor'] as String?;
        final t = decoded['state'] as String?;
        if (a != null && t != null) {
          anchor = a;
          state = t;
        }
      } catch (e) {
        log(
          'JMAP-sync: unreadable full-sync resume point for '
          'mailbox=$mailboxJmapId ($e) — starting over',
        );
      }
    }
    var resumed = anchor != null;
    if (resumed) {
      log(
        'JMAP-sync: resuming full sync mailbox=$mailboxJmapId anchor=$anchor',
      );
    }

    var fetched = 0;
    var bytes = 0;
    var pages = 0;
    int? reportedTotal;
    var truncated = false;
    var drained = false;
    var restartedOnce = false;
    final seenIds = <String>{};

    while (pages < _jmapFullSyncPagesPerRun) {
      // Anchor-based once we have an anchor (resumed, or after page one of a
      // fresh run); `position: 0` only for the very first page of a fresh run.
      final query = <String, dynamic>{
        'accountId': jmap.accountId,
        'filter': {'inMailbox': mailboxJmapId},
        'sort': [
          {'property': 'receivedAt', 'isAscending': false},
        ],
        'limit': _jmapPageSize,
        'calculateTotal': true,
        if (anchor != null) ...{'anchor': anchor, 'anchorOffset': 1} else
          'position': 0,
      };
      final methodCalls = <List<dynamic>>[
        ['Email/query', query, '0'],
        // `Email/get` with an empty `ids` list returns the Email state and
        // nothing else (RFC 8620 §5.1 — `ids: null` would mean *every* email).
        // Captured once, before any body is fetched, so a change landing
        // during a long full sync is picked up by the next incremental sweep.
        // Reused across runs via the resume point rather than re-probed.
        if (state == null)
          [
            'Email/get',
            {'accountId': jmap.accountId, 'ids': <String>[]},
            '1',
          ],
      ];
      final responses = await jmap.call(methodCalls);

      // A resumed run's anchor may have been destroyed since it was stored.
      // The server then cannot place the anchor in the result set and returns
      // `anchorNotFound`; restart the whole mailbox from the top, once.
      final triple = responses[0] as List<dynamic>;
      if (triple[0] == 'error') {
        final type = (triple[1] as Map<String, dynamic>)['type'];
        if (type == 'anchorNotFound' && !restartedOnce) {
          log(
            'JMAP-sync: full-sync anchor gone for mailbox=$mailboxJmapId — '
            'restarting from the top',
          );
          await _clearSyncState(accountId, resumeKey);
          anchor = null;
          state = null;
          resumed = false;
          restartedOnce = true;
          seenIds.clear();
          fetched = 0;
          bytes = 0;
          pages = 0;
          reportedTotal = null;
          continue;
        }
        throw JmapException('Email/query error: $type');
      }

      final queryResult = triple[1] as Map<String, dynamic>;
      final ids = List<String>.from(queryResult['ids'] as List);
      reportedTotal = (queryResult['total'] as int?) ?? reportedTotal;
      state ??= _responseArgs(responses, 1, 'Email/get')['state'] as String;
      final seenBefore = seenIds.length;
      seenIds.addAll(ids);

      final batched = await _fetchJmapEmailBatches(
        accountId,
        jmap,
        ids,
        mailboxJmapId: mailboxJmapId,
        deleteMissing: false,
      );
      fetched += batched.fetched;
      bytes += batched.bytes;
      pages++;

      if (ids.isEmpty) {
        drained = true;
        break;
      }
      anchor = ids.last;
      // A page that adds nothing new means the server is not honouring the
      // anchor (or a proxy is replaying a response). Stop rather than
      // re-fetching the same bodies up to the page cap.
      if (seenIds.length == seenBefore) {
        truncated = true;
        log(
          'JMAP-sync: full mailbox=$mailboxJmapId stalled — Email/query '
          'stopped returning new ids',
        );
        break;
      }
      // Prefer the server's own count; fall back to "a short page is the end"
      // only when it does not report one. Not breaking outright on an absent
      // total: that used to truncate a mailbox to its first page.
      if (reportedTotal != null) {
        if (seenIds.length >= reportedTotal) {
          drained = true;
          break;
        }
      } else if (ids.length < _jmapPageSize) {
        drained = true;
        break;
      }
    }

    if (truncated) {
      // Checkpointing here would be the worst outcome available: storing the
      // state switches the mailbox to the incremental path, and
      // `Email/changes` only reports what happened after it, so everything the
      // truncated walk never reached would be unreachable by any path. Leave
      // the mailbox on the full-sync path (resume key untouched) to retry.
      unawaited(
        _appLogger?.warn(
          'jmap_sync.full_sync_truncated',
          'Full sync of a mailbox stopped before the end; it will be retried',
          accountId: accountId,
          data: {
            'mailbox': mailboxJmapId,
            'pages': pages,
            'seen': seenIds.length,
            'total': reportedTotal,
          },
        ),
      );
      return model.SyncEmailsResult(
        fetched: fetched,
        skipped: 0,
        bytesTransferred: bytes,
      );
    }

    final reconcileKey = 'JMAP:Reconcile:$mailboxJmapId';

    if (!drained) {
      // Paused at the per-run page cap. Persist the anchor so the next cycle
      // continues, and leave `JMAP:Email:` unset so path selection keeps this
      // mailbox on the full-sync path. Stamp the reconcile marker to keep the
      // periodic pass from walking a half-synced mailbox every cycle.
      await _saveSyncState(
        accountId,
        resumeKey,
        jsonEncode({'anchor': anchor, 'state': state}),
      );
      await _saveSyncState(
        accountId,
        reconcileKey,
        DateTime.now().toIso8601String(),
      );
      log(
        'JMAP-sync: full mailbox=$mailboxJmapId paused after $pages page(s), '
        'fetched=$fetched anchor=$anchor',
      );
      return model.SyncEmailsResult(
        fetched: fetched,
        skipped: 0,
        bytesTransferred: bytes,
      );
    }

    // Drained. `seenIds` covers the whole mailbox only for a fresh sync that
    // finished in one invocation; a sync spread over several runs holds just
    // the final run's pages, so it cannot prune — the other runs' ids would
    // all look absent and be deleted. Hand pruning to the periodic reconcile,
    // which re-lists the mailbox from scratch (and, post-#1016, declines
    // safely if that listing is itself incomplete).
    final complete =
        !resumed && _jmapEnumerationComplete(seenIds, reportedTotal);
    var pruned = 0;
    if (complete) {
      pruned = await _pruneJmapMailboxToServerIds(
        accountId,
        mailboxJmapId,
        seenIds,
      );
    }
    log(
      'JMAP-sync: full mailbox=$mailboxJmapId fetched=$fetched pruned=$pruned '
      'complete=$complete resumed=$resumed total=$reportedTotal',
    );

    await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', state!);
    await _clearSyncState(accountId, resumeKey);
    if (complete) {
      // Pruned exhaustively just now, so hold the periodic pass off for its
      // normal interval.
      await _saveSyncState(
        accountId,
        reconcileKey,
        DateTime.now().toIso8601String(),
      );
    } else {
      // Nothing was pruned (a resumed drain can't), so make the reconcile due
      // now rather than leaving a stamp to defer it: `_syncEmailsJmap` runs it
      // immediately after this returns.
      await _clearSyncState(accountId, reconcileKey);
    }
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  /// Fetches [ids] in `Email/get` batches of [_jmapGetBatchSize], upserting
  /// each batch as it arrives. Returns how many emails were stored and how
  /// many bytes that was.
  ///
  /// Batched because the request also asks for full bodies: one `Email/get`
  /// for an unbounded id list makes the server read and serialize every
  /// message before it can answer, which is what blew past the request
  /// timeout in #967.
  /// Set [deleteMissing] false when the caller has its own, safer reconciler.
  /// The full sync finishes with [_pruneJmapMailboxToServerIds], which keeps
  /// everything `Email/query` listed and skips rows that are local-only
  /// (#545) or carry an unflushed optimistic move/snooze. Deleting here would
  /// pre-empt that with neither guard, so a pending offline move of a message
  /// another client had already destroyed would take the local row with it.
  Future<({int fetched, int bytes})> _fetchJmapEmailBatches(
    String accountId,
    JmapClient jmap,
    List<String> ids, {
    String? mailboxJmapId,
    bool deleteMissing = true,
  }) async {
    var fetched = 0;
    var bytes = 0;
    for (var i = 0; i < ids.length; i += _jmapGetBatchSize) {
      final batch = ids.sublist(
        i,
        math.min(i + _jmapGetBatchSize, ids.length),
      );
      final flagRead = await _startServerFlagRead(accountId);
      final Map<String, dynamic> result;
      final List<dynamic> list;
      try {
        final responses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': batch,
              'properties': _emailProperties,
              ..._emailGetBodyOptions,
            },
            '0',
          ],
        ]);
        result = _responseArgs(responses, 0, 'Email/get');
        list = result['list'] as List<dynamic>;
        bytes += await _upsertJmapEmails(
          accountId,
          list,
          currentMailboxJmapId: mailboxJmapId,
          flagRead: flagRead,
        );
      } finally {
        _endServerFlagRead();
      }
      fetched += list.length;

      if (!deleteMissing) continue;
      // RFC 8620 §5.1: the server names every requested id it does not have,
      // in `notFound`. Only ids it names there are deleted.
      //
      // This used to infer absence by subtracting the returned ids from the
      // batch, which read *any* short response as a deletion order — a
      // truncated list, or one object the server failed to serialize, and the
      // mail was gone locally. Verified against Stalwart 0.14.1, which
      // populates the field for absent and destroyed ids alike, including
      // alongside the body options this request sends.
      //
      // Parsed defensively on purpose: this field was inert before, and a
      // throw here would escape before the page's state is checkpointed,
      // stalling the mailbox permanently on the same page — the failure shape
      // [_jmapGetBatchSize] exists to prevent. Junk therefore means "delete
      // nothing".
      //
      // Keeping a row the server merely omitted costs a stale row rather than
      // costing mail: the periodic [_maybeReconcileJmapMailbox] prune clears
      // genuine ghosts. Not instantly and not unconditionally, though — the
      // interval is 15 minutes *per successful sync of that mailbox*, so on a
      // device syncing in the background the real window is longer, and a
      // mailbox the sync loop skips entirely (`isDuplicateOfOtherFolders`,
      // i.e. role `all`) is never reconciled at all. Worth it for a stale
      // row; it would not be worth it for lost mail, which is the trade.
      final rawNotFound = result['notFound'];
      final notFound = rawNotFound is List
          ? rawNotFound.whereType<String>().toSet()
          : const <String>{};

      final returnedIds = <String>{
        for (final e in list) (e as Map<String, dynamic>)['id'] as String,
      };

      // An id the server both returned and disclaimed is contradictory; keep
      // what it handed over. Without this the row would be upserted above and
      // deleted below, losing a message the server did supply — worse than
      // the subtraction this replaced.
      final missing = [
        for (final jmapId in batch)
          if (notFound.contains(jmapId) && !returnedIds.contains(jmapId))
            jmapId,
      ];

      // Computed for every batch, not just when nothing was disclaimed: a
      // response that names one id and silently drops another is exactly the
      // partial response this change is about, and it has a non-empty
      // `missing`.
      final unaccounted = [
        for (final jmapId in batch)
          if (!returnedIds.contains(jmapId) && !notFound.contains(jmapId))
            jmapId,
      ];
      if (unaccounted.isNotEmpty) {
        unawaited(
          _appLogger?.warn(
            'jmap_sync.email_get_incomplete',
            'Email/get neither returned nor disclaimed '
                '${unaccounted.length} of ${batch.length} requested ids — '
                'keeping those rows',
            accountId: accountId,
            data: {
              'mailbox': mailboxJmapId,
              'requested': batch.length,
              'returned': returnedIds.length,
              'notFound': notFound.length,
              'unaccounted': _briefIds(unaccounted),
            },
          ),
        );
      }

      if (missing.isEmpty) continue;
      // Guarded: a row carrying any unflushed user edit is held back, so a
      // queued change always has a row to apply to. Not a promise the mail
      // survives — the unguarded `destroyed` loop below deletes it once the
      // server reports it explicitly, and the periodic prune clears it
      // otherwise. It delays deletion until something else confirms it.
      //
      // The guard is "has an unflushed mutation of any kind", not the
      // move/snooze subset [_pruneJmapMailboxToServerIds] uses. That subset is
      // right for a *mailbox-scoped* walk, where an optimistic move has
      // already rewritten `mailboxPath` and makes the row look orphaned from
      // both folders. This path is keyed by id, so the only thing that matters
      // is whether the user has an edit in flight — an unflushed star counts
      // just as much as an unflushed move.
      //
      // Deliberately inside the loop: `_upsertJmapEmails` can enqueue changes
      // of its own via the #545 dissolve, so hoisting this lookup out would
      // read a stale set.
      final inFlight = await _inFlightFlagResourceIds(accountId);
      for (final jmapId in missing) {
        final row = await _rowByJmapId(accountId, jmapId);
        if (row != null && inFlight.contains(row.id)) {
          log(
            'JMAP-sync: Email/get disclaimed $jmapId but an edit is still '
            'queued for it — keeping the row for now',
          );
          continue;
        }
        await _deleteJmapEmailById(accountId, jmapId);
      }
    }
    return (fetched: fetched, bytes: bytes);
  }

  /// Requests one page of `Email/changes`.
  ///
  /// [maxChanges] is nullable so the caller can retry unbounded: RFC 8620 §5.2
  /// allows a server to answer `cannotCalculateChanges` when it cannot produce
  /// an update to an intermediate state, which a bounded request is what asks
  /// it for. Retrying without the bound tells a server that merely dislikes
  /// windowing apart from one whose stored state is genuinely too old.
  Future<List<dynamic>> _jmapEmailChanges(
    JmapClient jmap,
    String sinceState, {
    required int? maxChanges,
  }) async {
    final responses = await jmap.call([
      [
        'Email/changes',
        {
          'accountId': jmap.accountId,
          'sinceState': sinceState,
          if (maxChanges != null) 'maxChanges': maxChanges,
        },
        '0',
      ],
    ]);
    return responses[0] as List<dynamic>;
  }

  Future<model.SyncEmailsResult> _jmapIncrementalEmailSync(
    String accountId,
    JmapClient jmap,
    String sinceState, {
    String? mailboxJmapId,
  }) async {
    var fetched = 0;
    var bytes = 0;
    var state = sinceState;

    // RFC 8620 §5.2: /changes is a paged API. Ask for a bounded window and
    // keep going while the server reports `hasMoreChanges`, so a backlog is
    // drained over several small requests that each finish well inside the
    // request timeout.
    for (var page = 0; page < _jmapMaxPagesPerSync; page++) {
      var triple = await _jmapEmailChanges(
        jmap,
        state,
        maxChanges: _jmapMaxChanges,
      );

      // RFC 8620 §5.2 lists cannotCalculateChanges both for a sinceState the
      // server can no longer resolve (GC after long inactivity) and for one it
      // cannot step to an intermediate state from. Only the bounded request
      // can provoke the second, so retry unbounded before concluding the
      // stored state is dead and forcing a full resync.
      if (triple[0] == 'error' &&
          (triple[1] as Map<String, dynamic>)['type'] ==
              'cannotCalculateChanges') {
        log(
          'JMAP-sync: Email/changes refused a bounded window for '
          'mailbox=$mailboxJmapId — retrying without maxChanges',
        );
        triple = await _jmapEmailChanges(jmap, state, maxChanges: null);
      }

      if (triple[0] == 'error') {
        final err = triple[1] as Map<String, dynamic>;
        final type = err['type'] as String?;
        log(
          'JMAP-sync: Email/changes error type=$type mailbox=$mailboxJmapId '
          'sinceState=$state — falling back to full sync',
        );
        if (type == 'cannotCalculateChanges') {
          await _clearJmapSyncState(accountId, mailboxJmapId);
          if (mailboxJmapId != null) {
            // Keep whatever earlier pages already stored: the full sync is
            // exhaustive, but its counters only cover what it fetched itself.
            final full =
                await _jmapFullEmailSync(accountId, jmap, mailboxJmapId);
            return model.SyncEmailsResult(
              fetched: fetched + full.fetched,
              skipped: full.skipped,
              bytesTransferred: bytes + full.bytesTransferred,
            );
          }
        }
        throw JmapException('Email/changes error: $type');
      }

      final changes = triple[1] as Map<String, dynamic>;
      final newState = changes['newState'] as String;
      final created = List<String>.from(changes['created'] as List? ?? []);
      final updated = List<String>.from(changes['updated'] as List? ?? []);
      final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);
      final hasMoreChanges = changes['hasMoreChanges'] as bool? ?? false;

      log(
        'JMAP-sync: incremental mailbox=$mailboxJmapId '
        '$state → $newState '
        'created=${_briefIds(created)} '
        'updated=${_briefIds(updated)} '
        'destroyed=${_briefIds(destroyed)} '
        'hasMoreChanges=$hasMoreChanges',
      );

      final batched = await _fetchJmapEmailBatches(
        accountId,
        jmap,
        [...created, ...updated],
        mailboxJmapId: mailboxJmapId,
      );
      fetched += batched.fetched;
      bytes += batched.bytes;

      for (final jmapId in destroyed) {
        await _deleteJmapEmailById(accountId, jmapId);
      }

      // Checkpoint every page. A failure in a later page then costs one page
      // on the next cycle instead of replaying the whole backlog — which is
      // the half of #967 that made the account never catch up.
      await _saveSyncState(accountId, 'Email', newState);
      if (mailboxJmapId != null) {
        await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', newState);
      }

      // Caught up.
      if (!hasMoreChanges) {
        return model.SyncEmailsResult(
          fetched: fetched,
          skipped: 0,
          bytesTransferred: bytes,
        );
      }

      // A server that reports more changes without advancing the state token
      // would spin this loop forever. Stop and let the next cycle retry.
      // (Verified against Stalwart 0.14, which always advances.)
      if (newState == state) {
        log(
          'JMAP-sync: Email/changes reported hasMoreChanges without advancing '
          'state ($state) for mailbox=$mailboxJmapId — stopping this run',
        );
        break;
      }
      state = newState;
    }

    // Out of pages. The state is checkpointed, so the next cycle resumes from
    // here rather than starting over; draining a large backlog over several
    // cycles beats one request run that a background job will be killed in
    // the middle of.
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  /// Deletes the row for a server-side id.
  ///
  /// Unlike [_pruneJmapMailboxToServerIds] this needs no `isLocal` guard: that
  /// one walks every row in a mailbox, where local self-sent "virtual" rows
  /// (#545) genuinely appear, whereas this is keyed by an id the server gave
  /// us, and a virtual row records none.
  Future<void> _deleteJmapEmailById(String accountId, String jmapId) async {
    final email = await _rowByJmapId(accountId, jmapId);
    if (email == null) return;
    final tid = email.threadId ?? email.id;
    await (_db.delete(_db.emails)..where((t) => t.id.equals(email.id))).go();
    await _updateThread(accountId, email.mailboxPath, tid);
  }

  Future<void> _clearJmapSyncState(
    String accountId,
    String? mailboxJmapId,
  ) async {
    // Scoped to the one mailbox when we have it. Clearing every
    // `JMAP:Email:%` row would force a full resync of every folder in the
    // account over one folder's unresolvable state — and bounded
    // `Email/changes` requests make that error reachable where it was not
    // before (#967).
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (mailboxJmapId == null
                    ? (t.resourceType.equals('Email') |
                        t.resourceType.like('JMAP:Email:%') |
                        t.resourceType.like('JMAP:FullSync:%'))
                    : (t.resourceType.equals('Email') |
                        t.resourceType.equals('JMAP:Email:$mailboxJmapId') |
                        t.resourceType.equals('JMAP:FullSync:$mailboxJmapId'))),
          ))
        .go();
  }

  /// Row ids whose optimistic move, snooze or unsnooze has not been flushed
  /// yet, so a mailbox-scoped reconciler must not delete them mid-flight: the
  /// move has already rewritten `mailboxPath`, which makes the row look
  /// orphaned from the folder it left and the one it has not arrived in.
  ///
  /// For a guard that only needs "does the user have an edit in flight", use
  /// [_SyncImap._inFlightFlagResourceIds] — it covers flag edits and deletes too.
  /// A failed move or snooze is not counted: its row follows the server.
  Future<Set<String>> _rowsWithUnflushedMoveOrSnooze(String accountId) async {
    final ids = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.state.isIn(_liveStates) &
                _db.pendingChanges.changeType.isIn(
                  const ['move', 'snooze', 'unsnooze'],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    return ids.toSet();
  }

  /// Deletes local email rows for [mailboxJmapId] whose id isn't in the
  /// authoritative [serverIds] set. Returns the number of rows removed.
  ///
  /// Mirrors [_SyncImap._reconcileDeletedImap]: skips rows with a pending optimistic
  /// move/snooze so we don't wipe them mid-flight, and updates affected
  /// threads. `serverIds` are raw JMAP email ids (no `accountId:` prefix).
  Future<int> _pruneJmapMailboxToServerIds(
    String accountId,
    String mailboxJmapId,
    Set<String> serverIds,
  ) async {
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();

    final inFlightSet = await _rowsWithUnflushedMoveOrSnooze(accountId);

    final affectedThreads = <String>{};
    var removed = 0;
    for (final row in localRows) {
      // Local self-sent "virtual" rows have no server counterpart and must
      // survive until the real message arrives and dissolves them (#545).
      if (row.isLocal) continue;
      // No recorded server id: unknown is not missing.
      final jmapId = row.srvJmapId;
      if (jmapId == null || serverIds.contains(jmapId)) continue;
      if (inFlightSet.contains(row.id)) continue;
      affectedThreads.add(row.threadId ?? row.id);
      await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      removed++;
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxJmapId, tid);
    }
    return removed;
  }

  /// Periodic safety net: at most once per [_jmapReconcileInterval] per
  /// mailbox, list all server-side email ids in [mailboxJmapId] and prune
  /// local rows no longer present. Also refreshes `keywords` for every
  /// email still in the mailbox and rewrites `isSeen` / `isFlagged` from
  /// server truth. Catches ghosts and flag drift from Email/changes
  /// under-reporting — Stalwart's IMAP-triggered mailbox moves have surfaced
  /// this for existence (#262) and Stalwart 0.14.x similarly under-reports
  /// keyword changes to the paired IMAP account, causing "seen" drift on the
  /// compare view (#407).
  Future<void> _maybeReconcileJmapMailbox(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    final key = 'JMAP:Reconcile:$mailboxJmapId';
    final last = await _loadSyncState(accountId, key);
    final dueValue = await _loadSyncState(
      accountId,
      _flagReconcileDueKey(mailboxJmapId, jmap: true),
    );
    if (last != null && dueValue == null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _jmapReconcileInterval) {
        return;
      }
    }

    final serverIds = <String>{};
    int position = 0;
    var pages = 0;
    int? reportedTotal;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            // Same explicit sort as the full sync. Position paging over a
            // server-chosen default order is free to duplicate and skip ids
            // between pages, which this pass would then read as an incomplete
            // walk and decline to prune on.
            'sort': [
              {'property': 'receivedAt', 'isAscending': false},
            ],
            'limit': _jmapPageSize,
            'position': position,
            'calculateTotal': true,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      reportedTotal = (queryResult['total'] as int?) ?? reportedTotal;
      final seenBefore = serverIds.length;
      serverIds.addAll(ids);
      position += ids.length;
      pages++;
      if (ids.isEmpty) break;
      if (serverIds.length == seenBefore) break;
      if (reportedTotal != null) {
        if (position >= reportedTotal) break;
      } else if (ids.length < _jmapPageSize) {
        break;
      }
      if (pages >= _jmapMaxQueryPages) break;
    }

    // Only the prune is gated. An enumeration this pass cannot vouch for is
    // the most dangerous input in the file — it runs on every mailbox, so one
    // bad `Email/query` used to be enough to empty a folder — but the work
    // below it is safe on a partial set and must not be skipped with it:
    // `_reconcileJmapFlagsForMailbox` only touches rows the walk *did* see,
    // and `_sweepOrphanThreads` only removes threads with no emails left.
    // Skipping them would mean flag drift (#407) and phantom threads (#523)
    // were never corrected for exactly the mailboxes having trouble.
    if (_jmapEnumerationComplete(serverIds, reportedTotal)) {
      final removed = await _pruneJmapMailboxToServerIds(
        accountId,
        mailboxJmapId,
        serverIds,
      );
      if (removed > 0) {
        log(
          'JMAP-sync: reconcile mailbox=$mailboxJmapId pruned=$removed '
          '(server=${serverIds.length})',
        );
      }
    } else {
      log(
        'JMAP-sync: reconcile mailbox=$mailboxJmapId walked ${serverIds.length}'
        ' of ${reportedTotal ?? -1} after $pages page(s) — skipping the prune',
      );
    }
    await _reconcileJmapFlagsForMailbox(
      accountId,
      jmap,
      mailboxJmapId,
      serverIds,
    );
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
    await _settleFlagReconcileDue(
      accountId,
      mailboxJmapId,
      jmap: true,
      dueValue: dueValue,
    );
  }

  /// Fetches `keywords` for every local row in [mailboxJmapId] whose JMAP id
  /// is still on the server and rewrites `isSeen` / `isFlagged` from truth.
  /// Skips rows whose flag change is still queued in `pendingChanges` so an
  /// unflushed optimistic edit is not silently reverted.
  Future<void> _reconcileJmapFlagsForMailbox(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
    Set<String> serverIds,
  ) async {
    if (serverIds.isEmpty) return;

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();
    if (localRows.isEmpty) return;

    final localByJmapId = <String, Email>{
      for (final r in localRows)
        if (r.srvJmapId != null) r.srvJmapId!: r,
    };

    final inFlightSet = await _inFlightFlagResourceIds(accountId);

    final toCheck = [
      for (final jmapId in localByJmapId.keys)
        if (serverIds.contains(jmapId) &&
            !inFlightSet.contains(localByJmapId[jmapId]!.id))
          jmapId,
    ];
    if (toCheck.isEmpty) return;

    final affectedThreads = <String>{};
    final sizeById = <String, int>{};
    var corrected = 0;
    for (var offset = 0; offset < toCheck.length; offset += _jmapPageSize) {
      final batch = toCheck.sublist(
        offset,
        math.min(offset + _jmapPageSize, toCheck.length),
      );
      final flagRead = await _startServerFlagRead(accountId);
      try {
        final responses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': batch,
              // `size` backfills rows cached before schema v64.
              'properties': ['id', 'keywords', 'size'],
            },
            '0',
          ],
        ]);
        final getResult = _responseArgs(responses, 0, 'Email/get');
        final list = getResult['list'] as List<dynamic>;
        final queuedNow = await _inFlightFlagResourceIds(accountId);
        for (final e in list) {
          final m = e as Map<String, dynamic>;
          final jmapId = m['id'] as String;
          final row = localByJmapId[jmapId];
          if (row == null) continue;
          final size = m['size'];
          if (row.sizeBytes == null && size is int) sizeById[row.id] = size;
          final keywords = (m['keywords'] as Map<String, dynamic>?) ?? {};
          final serverSeen = keywords.containsKey(r'$seen');
          final serverFlagged = keywords.containsKey(r'$flagged');
          if (serverSeen == row.isSeen && serverFlagged == row.isFlagged) {
            continue;
          }
          // `row` was read before the first batch; a change made since is
          // newer than this answer.
          if (flagRead.protects(row.id, queuedNow)) continue;
          await (_db.update(_db.emails)..where((t) => t.id.equals(row.id)))
              .write(
            EmailsCompanion(
              isSeen: Value(serverSeen),
              isFlagged: Value(serverFlagged),
            ),
          );
          affectedThreads.add(row.threadId ?? row.id);
          corrected++;
        }
      } finally {
        _endServerFlagRead();
      }
    }

    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxJmapId, tid);
    }
    await _backfillSizes(sizeById);
    if (corrected > 0) {
      log(
        'JMAP-sync: flag-reconcile mailbox=$mailboxJmapId corrected=$corrected '
        '(checked=${toCheck.length}, local=${localRows.length})',
      );
    }
  }

  String _briefIds(List<String> ids, {int keep = 10}) {
    if (ids.length <= keep) return '${ids.length}:$ids';
    return '${ids.length}:${ids.take(keep).toList()}+${ids.length - keep} more';
  }

  // Returns total bytes transferred (sum of JMAP `size` fields).
  //
  // [currentMailboxJmapId], when provided, is the mailbox whose sync triggered
  // this fetch. It is used to pick a stable [mailboxPath] for messages that
  // are members of multiple mailboxes: we prefer the row's existing
  // `mailboxPath` when it's still a member, then [currentMailboxJmapId], and
  // finally any remaining membership. Without this, `Map.keys.firstOrNull`
  // picks an arbitrary mailbox and a message moved out of [currentMailboxJmapId]
  // may keep showing there indefinitely (#262).
  Future<int> _upsertJmapEmails(
    String accountId,
    List<dynamic> emails, {
    String? currentMailboxJmapId,
    required _ServerFlagRead flagRead,
  }) async {
    var bytes = 0;
    final queuedNow = await _inFlightFlagResourceIds(accountId);
    final affectedByMailbox = <String, Set<String>>{};
    // (mailboxPath, realEmailId, messageId) of each row we just wrote — checked
    // afterwards for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String, String?)>[];
    // (emailId, mailboxPath, subject, size) of each row stored for the first
    // time — logged so "Show Logs" starts with the fetch (#920).
    final newlyStored = <(String, String, String?, int?)>[];
    for (final e in emails) {
      final m = e as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      bytes += (m['size'] as int?) ?? 0;
      // Found by the server id; without one the mail gets a new row with
      // a new id.
      final existingRow = await _rowByJmapId(accountId, jmapId);
      final dbId = existingRow?.id ?? _newId(accountId);

      final mailboxIds = m['mailboxIds'] as Map<String, dynamic>?;

      // If the mail is no longer in any mailbox, treat it as gone. This
      // shouldn't normally reach us via Email/get (destroyed mails end up in
      // Email/changes.destroyed) but is defensive against unusual server
      // states where mailboxIds is empty.
      if (mailboxIds == null || mailboxIds.isEmpty) {
        if (existingRow != null) {
          final tid = existingRow.threadId ?? dbId;
          final oldMailbox = existingRow.mailboxPath;
          await (_db.delete(_db.emails)..where((t) => t.id.equals(dbId))).go();
          affectedByMailbox.putIfAbsent(oldMailbox, () => {}).add(tid);
        }
        continue;
      }

      final String mailboxPath;
      if (existingRow != null &&
          mailboxIds.containsKey(existingRow.mailboxPath)) {
        // Stable: keep the mailbox we already display it under.
        mailboxPath = existingRow.mailboxPath;
      } else if (currentMailboxJmapId != null &&
          mailboxIds.containsKey(currentMailboxJmapId)) {
        mailboxPath = currentMailboxJmapId;
      } else {
        mailboxPath = mailboxIds.keys.first;
      }

      // Membership changed: the mail is no longer in the mailbox where the
      // local row lived (e.g. IMAP "move to Trash" via Thunderbird — #262).
      // Refresh the thread aggregate for the old mailbox so it no longer
      // lists this email; the new mailbox is refreshed below via
      // affectedByMailbox.
      if (existingRow != null && existingRow.mailboxPath != mailboxPath) {
        affectedByMailbox
            .putIfAbsent(existingRow.mailboxPath, () => {})
            .add(existingRow.threadId ?? dbId);
        log(
          'JMAP-sync: mailbox change id=$jmapId '
          '${existingRow.mailboxPath} → $mailboxPath',
        );
      }

      final keywords = m['keywords'] as Map<String, dynamic>? ?? {};
      DateTime? snoozedUntil;
      for (final String k in keywords.keys) {
        if (k.startsWith('snz:')) {
          final ts = k.substring(4);
          if (ts.length >= 15) {
            final formatted =
                '${ts.substring(0, 4)}-${ts.substring(4, 6)}-${ts.substring(6, 8)}T${ts.substring(9, 11)}:${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
            snoozedUntil = DateTime.tryParse(formatted);
          }
          break;
        }
      }

      final from = _encodeJmapAddresses(m['from'] as List<dynamic>?);
      final to = _encodeJmapAddresses(m['to'] as List<dynamic>?);
      final cc = _encodeJmapAddresses(m['cc'] as List<dynamic>?);
      final replyTo = _encodeJmapAddresses(m['replyTo'] as List<dynamic>?);
      final bcc = _encodeJmapAddresses(m['bcc'] as List<dynamic>?);
      final sentAt = _parseDate(m['sentAt'] as String?);
      final receivedAt =
          _parseDate(m['receivedAt'] as String?) ?? DateTime.now();

      final jmapThreadId = m['threadId'] as String? ?? dbId;
      affectedByMailbox.putIfAbsent(mailboxPath, () => {}).add(jmapThreadId);

      // JMAP messageId/inReplyTo/references are arrays; join to space-separated.
      final jmapMessageId = _joinJmapStringList(
        m['messageId'] as List<dynamic>?,
      );
      final jmapInReplyTo = _joinJmapStringList(
        m['inReplyTo'] as List<dynamic>?,
      );
      final jmapReferences = _joinJmapStringList(
        m['references'] as List<dynamic>?,
      );
      final jmapListUnsubscribe =
          (m['header:List-Unsubscribe:asText'] as String?)?.trim();
      // Re-decode Subject from the raw header when the server exposes it, so
      // we get the same defensive handling as the IMAP path (#418). Falls
      // back to the server-decoded `subject` property when the raw header is
      // absent (e.g. mail with no Subject at all, or servers that reject
      // `header:*:asRaw`).
      final rawSubjectHeader = m['header:Subject:asRaw'] as String?;
      final subject = rawSubjectHeader != null
          ? (decodeMailHeader(rawSubjectHeader) ?? m['subject'] as String?)
          : m['subject'] as String?;

      // An existing row the user just changed keeps its read/star state:
      // this answer may predate the change (or the change is still queued).
      final keepLocalFlags =
          existingRow != null && flagRead.protects(dbId, queuedNow);

      await _db.into(_db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: dbId,
              accountId: accountId,
              mailboxPath: mailboxPath,
              uid: 0, // not used for JMAP accounts
              subject: Value(subject),
              sentAt: Value(sentAt),
              receivedAt: receivedAt,
              fromJson: Value(from),
              toAddresses: Value(to),
              ccJson: Value(cc),
              replyToJson: Value(replyTo),
              bccJson: Value(bcc),
              sizeBytes: m['size'] is int
                  ? Value(m['size'] as int)
                  : const Value.absent(),
              preview: Value(m['preview'] as String?),
              // Absent leaves the stored value alone on conflict.
              isSeen: keepLocalFlags
                  ? const Value.absent()
                  : Value(keywords.containsKey(r'$seen')),
              isFlagged: keepLocalFlags
                  ? const Value.absent()
                  : Value(keywords.containsKey(r'$flagged')),
              // Server-defined (RFC 8621); IMAP instead counts
              // Content-Disposition: attachment parts.
              hasAttachment: Value((m['hasAttachment'] as bool?) ?? false),
              threadId: Value(jmapThreadId),
              messageId: Value(jmapMessageId),
              inReplyTo: Value(jmapInReplyTo),
              references: Value(jmapReferences),
              snoozedUntil: Value(snoozedUntil),
              listUnsubscribeHeader: Value(jmapListUnsubscribe),
              srvJmapId: Value(jmapId),
            ),
          );

      // Cache body if the server included bodyValues in this response.
      if (m.containsKey('bodyValues')) {
        final (textBody, htmlBody, attachmentsJson) = _parseJmapBody(m);
        await _db.into(_db.emailBodies).insertOnConflictUpdate(
              EmailBodiesCompanion.insert(
                emailId: dbId,
                textBody: Value(textBody),
                htmlBody: Value(htmlBody),
                attachmentsJson: Value(attachmentsJson),
                cachedAt: Value(DateTime.now()),
                bodySize: Value(_bodySize(textBody, htmlBody)),
              ),
            );
      }
      dissolveCandidates.add((mailboxPath, dbId, jmapMessageId));
      if (existingRow == null) {
        newlyStored.add((dbId, mailboxPath, subject, m['size'] as int?));
      }
    }
    for (final (emailId, mailboxPath, subject, size) in newlyStored) {
      _logEmailFetched(
        emailId: emailId,
        accountId: accountId,
        mailboxPath: mailboxPath,
        protocol: 'jmap',
        subject: subject,
        bytes: size,
      );
    }

    for (final mailboxPath in affectedByMailbox.keys) {
      for (final tid in affectedByMailbox[mailboxPath]!) {
        await _updateThread(accountId, mailboxPath, tid);
      }
    }
    if (dissolveCandidates.isNotEmpty && await _hasLocalMessages(accountId)) {
      for (final (mailboxPath, emailId, msgId) in dissolveCandidates) {
        await _maybeDissolveLocalMessage(
          accountId,
          mailboxPath,
          emailId,
          msgId,
        );
      }
    }
    return bytes;
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .getSingleOrNull();
    return row?.state;
  }

  /// Removes one sync-state row, so a checkpoint can be made due again (or a
  /// resume point retired) rather than merely left stale.
  Future<void> _clearSyncState(String accountId, String resourceType) async {
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .go();
  }

  Future<void> _saveSyncState(
    String accountId,
    String resourceType,
    String state,
  ) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  // ── JMAP helpers ─────────────────────────────────────────────────────────

  Map<String, dynamic> _responseArgs(
    List<dynamic> responses,
    int index,
    String expectedMethod,
  ) {
    final triple = responses[index] as List<dynamic>;
    final method = triple[0] as String;
    if (method == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      throw JmapException('$expectedMethod error: ${err['type']}');
    }
    // [expectedMethod] used to be for the error message only, so a response
    // list that had slipped out of step returned another method's arguments
    // and surfaced as an opaque TypeError further down. Say what happened.
    if (method != expectedMethod) {
      throw JmapException(
        'JMAP response $index is $method, expected $expectedMethod',
      );
    }
    return triple[1] as Map<String, dynamic>;
  }

  String _encodeJmapAddresses(dynamic addressList) {
    if (addressList == null) return '[]';
    final list = addressList as List<dynamic>;
    return jsonEncode(
      list
          .map(
            (a) => {
              'name': (a as Map<String, dynamic>)['name'],
              'email': a['email'],
            },
          )
          .toList(),
    );
  }

  DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);
}
