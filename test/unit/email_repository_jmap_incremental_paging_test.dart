// Regression coverage for issue #967.
//
// JMAP sync died with "Could not reach the mail server — temporary network or
// DNS problem" and never recovered. The server was healthy; the client was
// asking too much of it in one request. `Email/changes` was sent without
// `maxChanges`, so a backlog came back in a single response, and every id in it
// went into ONE `Email/get` that also asked for full HTML and text body values
// plus attachment metadata. That request cannot finish inside the client's
// request timeout.
//
// The second half of the bug is why it never recovered: the sync state was only
// checkpointed once the whole sweep succeeded, so every cycle re-requested the
// same oversized page from the same stored token. The sweep now pages
// `Email/changes` with `maxChanges`, fetches each page in bounded `Email/get`
// batches, and checkpoints the state after every page.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

/// Larger than the client's `maxChanges` (200) and its `Email/get` batch size
/// (50), so a single sweep has to page *and* batch. A backlog below either
/// bound would let a client that ignores both still pass.
const _backlog = 450;

/// What the client is allowed to ask for in one request. These mirror the
/// production constants; the test asserts against them absolutely rather than
/// against [_backlog], so it fails for a client that sends no bound at all.
const _maxChangesBound = 200;
const _getBatchBound = 50;

const _jmapAccount = Account(
  id: 'jmap-inc',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// What the fake server saw, so the test can assert on request shape.
class _Observed {
  /// `maxChanges` per `Email/changes`, null when the client sent no bound.
  final changesMaxChanges = <int?>[];
  final changesSinceStates = <String>[];
  final getBatchSizes = <int>[];
}

/// Fake JMAP server holding [_backlog] new emails, handed out through a paged
/// `Email/changes` exactly the way RFC 8620 §5.2 describes — and the way
/// Stalwart 0.14.1 was observed to behave: at most `maxChanges` ids per
/// response, `hasMoreChanges` until the backlog is drained, and a `newState`
/// that advances every page.
///
/// State tokens are `s<offset into the backlog>`, so the stored checkpoint is
/// directly readable as "how far did it get".
///
/// [failGetFromOffset] makes every `Email/get` fail once the sweep has passed
/// that offset, standing in for the server that could not answer in time.
http.Client _pagingServer(
  _Observed observed, {
  int? failGetFromOffset,
}) {
  final ids = [for (var i = 0; i < _backlog; i++) 'e$i'];
  final offsetOf = {for (var i = 0; i < _backlog; i++) 'e$i': i};

  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      if (call.method == 'Email/changes') {
        final sinceState = call.args['sinceState'] as String;
        final maxChanges = call.args['maxChanges'] as int?;
        observed.changesSinceStates.add(sinceState);
        observed.changesMaxChanges.add(maxChanges);

        final offset = int.parse(sinceState.substring(1));
        final end = (offset + (maxChanges ?? _backlog)).clamp(0, _backlog);
        return [
          'Email/changes',
          {
            'accountId': _jmapAccountId,
            'oldState': sinceState,
            'newState': 's$end',
            'hasMoreChanges': end < _backlog,
            'created': ids.sublist(offset, end),
            'updated': <String>[],
            'destroyed': <String>[],
          },
          call.callId,
        ];
      }

      if (call.method != 'Email/get') return null;

      observed.getBatchSizes.add(call.ids.length);
      final first = offsetOf[call.ids.first] ?? 0;
      if (failGetFromOffset != null && first >= failGetFromOffset) {
        // The server that could not answer in time, as an HTTP failure.
        throw JmapRawResponse(http.Response('upstream too slow', 503));
      }
      return jmapEmailGetResponseFor(
        accountId: _jmapAccountId,
        state: 's$_backlog',
        ids: call.ids,
        mailboxId: _mailbox,
        subjectPrefix: 'backlog',
        callId: call.callId,
      );
    },
  );
}

void main() {
  final cacheDir = useJmapTestEnv('jmap_inc_');

  test('pages Email/changes and batches Email/get', () async {
    final observed = _Observed();
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: _pagingServer(observed),
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
    );

    final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      result.fetched,
      _backlog,
      reason: 'every backlogged email must be stored',
    );
    expect(await r.db.select(r.db.emails).get(), hasLength(_backlog));

    // The point of the fix: no single request is unbounded.
    expect(
      observed.changesMaxChanges,
      everyElement(isNotNull),
      reason: 'Email/changes without maxChanges lets the server return the '
          'whole backlog in one response',
    );
    expect(
      observed.changesMaxChanges,
      everyElement(lessThanOrEqualTo(_maxChangesBound)),
    );
    expect(
      observed.getBatchSizes,
      everyElement(lessThanOrEqualTo(_getBatchBound)),
      reason: 'Email/get asks for full bodies, so its id list must be capped',
    );

    // Paged, resuming each time from the token the previous page returned.
    expect(observed.changesSinceStates.first, 's0');
    expect(
      observed.changesSinceStates,
      ['s0', 's200', 's400'],
      reason: 'each page must resume from the previous newState, never replay',
    );
    expect(
      await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
      's$_backlog',
    );

    await r.db.close();
  });

  // The half of #967 that made the account never catch up: with the state
  // written only after the whole sweep succeeded, a mid-sweep failure left the
  // checkpoint at its original value, so the next cycle asked for the same
  // backlog and failed the same way, forever.
  test('a mid-sweep failure keeps the pages that already landed', () async {
    final observed = _Observed();
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: _pagingServer(observed, failGetFromOffset: 200),
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
    );

    await expectLater(
      r.emails.syncEmails(_jmapAccount.id, _mailbox),
      throwsA(isA<Exception>()),
    );

    expect(
      await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
      's200',
      reason: 'the first page completed, so the next cycle must resume after '
          'it instead of replaying the whole backlog',
    );
    expect(
      await r.db.select(r.db.emails).get(),
      hasLength(200),
      reason: 'page one is stored even though page two failed',
    );

    await r.db.close();
  });

  test('a later cycle resumes from the checkpoint and finishes', () async {
    final observed = _Observed();
    // Stand in for a previous cycle that got as far as page one.
    final r = await openJmapTestReposOnIncrementalPath(
      httpClient: _pagingServer(observed),
      account: _jmapAccount,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's200',
    );

    final result = await r.emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(result.fetched, _backlog - 200);
    expect(observed.changesSinceStates.first, 's200');
    expect(
      observed.changesSinceStates,
      isNot(contains('s0')),
      reason: 'the checkpoint must be honoured, not restarted from scratch',
    );
    expect(
      await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'),
      's$_backlog',
    );

    await r.db.close();
  });
}
