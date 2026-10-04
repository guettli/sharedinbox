// Regression coverage for issue #967.
//
// JMAP sync died with "Could not reach the mail server — temporary network or
// DNS problem" and never recovered. The server was healthy; the client was
// asking too much of it in one request. `Email/changes` was sent without
// `maxChanges`, so a backlog came back in a single response, and every id in it
// went into ONE `Email/get` that also asked for full HTML and text body values
// plus attachment metadata. That request cannot finish inside the client's
// request timeout, and because the sync state was only checkpointed after the
// whole sweep succeeded, the next cycle re-requested the same oversized page —
// the account never caught up.
//
// The sweep now pages `Email/changes` with `maxChanges`, fetches each page in
// bounded `Email/get` batches, and checkpoints the state after every page.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';
const _backlog = 120;

const _jmapAccount = Account(
  id: 'jmap-inc',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// What the fake server saw, so the test can assert on request shape.
class _Observed {
  final List<int> changesMaxChanges = [];
  final List<int> getBatchSizes = [];
  final List<String> changesSinceStates = [];
}

/// Fake JMAP server holding [_backlog] new emails, handed out through a paged
/// `Email/changes` exactly the way RFC 8620 §5.2 describes (and the way
/// Stalwart 0.14 was observed to behave): at most `maxChanges` ids per
/// response, `hasMoreChanges` until the backlog is drained, and a `newState`
/// that advances every page.
http.Client _pagingServer(_Observed observed) {
  final ids = [for (var i = 0; i < _backlog; i++) 'e$i'];

  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'accounts': {
            _jmapAccountId: {'name': 'alice@example.com', 'isPersonal': true},
          },
          'primaryAccounts': {
            'urn:ietf:params:jmap:core': _jmapAccountId,
            'urn:ietf:params:jmap:mail': _jmapAccountId,
          },
          'capabilities': {
            'urn:ietf:params:jmap:core': <String, dynamic>{},
            'urn:ietf:params:jmap:mail': <String, dynamic>{},
          },
          'username': 'alice@example.com',
          'state': 'sess1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final methodCalls = (body['methodCalls'] as List<dynamic>).cast<List>();
    final methodResponses = <List<dynamic>>[];

    for (final call in methodCalls) {
      final method = call[0] as String;
      final args = call[1] as Map<String, dynamic>;
      final callId = call[2];

      if (method == 'Email/changes') {
        final sinceState = args['sinceState'] as String;
        final maxChanges = args['maxChanges'] as int?;
        observed.changesSinceStates.add(sinceState);
        // A client that omits maxChanges would get the whole backlog at once,
        // which is the bug this test guards against.
        observed.changesMaxChanges.add(maxChanges ?? _backlog);

        // State token is "s<offset into the backlog>".
        final offset = int.parse(sinceState.substring(1));
        final limit = maxChanges ?? _backlog;
        final end = (offset + limit).clamp(0, _backlog);
        methodResponses.add([
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
          callId,
        ]);
        continue;
      }

      if (method == 'Email/get') {
        final requested = (args['ids'] as List<dynamic>).cast<String>();
        observed.getBatchSizes.add(requested.length);
        methodResponses.add([
          'Email/get',
          {
            'accountId': _jmapAccountId,
            'state': 's$_backlog',
            'list': [
              for (final id in requested)
                {
                  'id': id,
                  'threadId': 't-$id',
                  'mailboxIds': {_mailbox: true},
                  'subject': 'backlog $id',
                  'receivedAt': '2026-10-04T10:00:00Z',
                  'from': [
                    {'email': 'bob@example.com'},
                  ],
                  'keywords': <String, dynamic>{},
                  'preview': 'hi',
                  'textBody': [
                    {'partId': '1', 'type': 'text/plain'},
                  ],
                  'htmlBody': <dynamic>[],
                  'bodyValues': {
                    '1': {'value': 'body of $id'},
                  },
                  'attachments': <dynamic>[],
                },
            ],
            'notFound': <String>[],
          },
          callId,
        ]);
        continue;
      }

      methodResponses.add([
        'error',
        {'type': 'unknownMethod'},
        callId,
      ]);
    }

    return http.Response(
      jsonEncode({'sessionState': 'sess1', 'methodResponses': methodResponses}),
      200,
    );
  });
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory cacheDir;
  setUp(() => cacheDir = Directory.systemTemp.createTempSync('jmap_inc_'));
  tearDown(() => cacheDir.deleteSync(recursive: true));

  test('incremental sync pages Email/changes and batches Email/get', () async {
    final observed = _Observed();
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      getCacheDir: () async => cacheDir,
      httpClient: _pagingServer(observed),
    );
    await accounts.addAccount(_jmapAccount, 'pw');

    // A stored state puts the sweep on the incremental path; a fresh reconcile
    // stamp keeps the periodic Email/query safety net out of this test.
    await db.into(db.syncStates).insert(
          SyncStatesCompanion.insert(
            accountId: _jmapAccount.id,
            resourceType: 'JMAP:Email:$_mailbox',
            state: 's0',
            syncedAt: DateTime.now(),
          ),
        );
    await db.into(db.syncStates).insert(
          SyncStatesCompanion.insert(
            accountId: _jmapAccount.id,
            resourceType: 'JMAP:Reconcile:$_mailbox',
            state: DateTime.now().toIso8601String(),
            syncedAt: DateTime.now(),
          ),
        );

    final result = await emails.syncEmails(_jmapAccount.id, _mailbox);

    expect(
      result.fetched,
      _backlog,
      reason: 'every backlogged email must be stored',
    );

    // The point of the fix: no single request is unbounded.
    expect(
      observed.changesMaxChanges,
      everyElement(lessThan(_backlog)),
      reason: 'Email/changes must carry a maxChanges bound',
    );
    expect(
      observed.getBatchSizes,
      everyElement(lessThanOrEqualTo(50)),
      reason: 'Email/get must be chunked, not one request per page',
    );
    expect(
      observed.changesSinceStates.length,
      greaterThan(1),
      reason: 'a backlog larger than maxChanges must be drained over pages',
    );
    expect(
      observed.changesSinceStates.first,
      's0',
      reason: 'the first page resumes from the stored state',
    );
    expect(
      observed.changesSinceStates,
      observed.changesSinceStates.toSet().toList(),
      reason: 'each page must advance the state, never replay one',
    );

    // State is checkpointed per page, so an interrupted catch-up resumes.
    final stored = await (db.select(db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(_jmapAccount.id) &
                t.resourceType.equals('JMAP:Email:$_mailbox'),
          ))
        .getSingle();
    expect(stored.state, 's$_backlog');

    final rows = await db.select(db.emails).get();
    expect(rows, hasLength(_backlog));

    await db.close();
  });
}
