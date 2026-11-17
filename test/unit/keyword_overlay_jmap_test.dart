// The `keywords` overlay on JMAP (SYNC.md §6a): an applied read/star change
// is acked and dropped by the `Email/get` that `Email/changes` leads to; the
// flag reconcile writes the server's keywords through the gate.

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

const _account = Account(
  id: 'jmap-kw',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

void main() {
  final cacheDir = useJmapTestEnv('keyword_overlay_jmap');

  late JmapTestRepos r;
  // The server's keywords of e1, and the ids Email/changes reports.
  late Map<String, bool> keywords;
  late List<String> changed;

  setUp(() async {
    keywords = {};
    changed = [];
    r = await openJmapTestReposOnIncrementalPath(
      httpClient: jmapFakeServer(
        accountId: _jmapAccountId,
        handle: (call) {
          switch (call.method) {
            case 'Email/set':
              final update = (call.args['update'] as Map<String, dynamic>)['e1']
                  as Map<String, dynamic>;
              for (final MapEntry(:key, :value) in update.entries) {
                if (!key.startsWith('keywords/')) continue;
                final keyword = key.substring('keywords/'.length);
                value == true
                    ? keywords[keyword] = true
                    : keywords.remove(keyword);
              }
              changed = ['e1'];
              return [
                'Email/set',
                {
                  'accountId': _jmapAccountId,
                  'oldState': 's0',
                  'newState': 's1',
                  'updated': {'e1': null},
                },
                call.callId,
              ];
            case 'Email/changes':
              final updated = changed;
              changed = [];
              return [
                'Email/changes',
                {
                  'accountId': _jmapAccountId,
                  'oldState': 's0',
                  'newState': 's0',
                  'hasMoreChanges': false,
                  'created': <String>[],
                  'updated': updated,
                  'destroyed': <String>[],
                },
                call.callId,
              ];
            case 'Email/get':
              return jmapEmailGetResponse(
                accountId: _jmapAccountId,
                state: 's0',
                list: [
                  jmapEmailObject(id: 'e1', mailboxId: _mailbox)
                    ..['keywords'] = {...keywords},
                ],
                callId: call.callId,
              );
            case 'Email/query':
              return [
                'Email/query',
                {
                  'accountId': _jmapAccountId,
                  'ids': ['e1'],
                  'position': 0,
                  'total': 1,
                  'queryState': 'q0',
                },
                call.callId,
              ];
          }
          return null;
        },
      ),
      account: _account,
      cacheDir: cacheDir(),
      mailboxJmapId: _mailbox,
      syncState: 's0',
    );
    await insertJmapEmailRow(r.db, _account.id, 'e1', mailboxPath: _mailbox);
  });
  tearDown(() => r.db.close());

  const id = 'jmap-kw:e1';
  Future<void> expectConsistent() async =>
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);

  test(
      'an applied change is acked, then dropped by the read Email/changes '
      'leads to', () async {
    await r.emails.setFlag(id, flagged: true);
    await r.emails.flushPendingChanges(_account.id, 'pw');

    expect(keywords, {r'$flagged': true});
    final acked = (await r.db.select(r.db.pendingChanges).get()).single;
    expect(acked.state, 'acked');
    expect((await r.emails.getEmail(id))!.isFlagged, isTrue);
    await expectConsistent();

    await r.emails.syncEmails(_account.id, _mailbox);

    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    final row = await (r.db.select(r.db.emails)..where((t) => t.id.equals(id)))
        .getSingle();
    expect(row.isFlagged, isTrue);
    expect(row.srvIsFlagged, isTrue);
    expect(row.localIsFlagged, isNull);
    await expectConsistent();
  });

  test(
      'the flag reconcile writes another client\'s change through the gate, '
      'under a queued one', () async {
    // Another client stars it; the user marks it read (not sent yet).
    keywords[r'$flagged'] = true;
    await r.emails.setFlag(id, seen: true);
    await r.db.into(r.db.syncStates).insert(
          SyncStatesCompanion.insert(
            accountId: _account.id,
            resourceType: 'JMAP:ReconcileDue:$_mailbox',
            state: DateTime.now().toIso8601String(),
            syncedAt: DateTime.now(),
          ),
        );

    await r.emails.syncEmails(_account.id, _mailbox);

    final row = await (r.db.select(r.db.emails)..where((t) => t.id.equals(id)))
        .getSingle();
    expect(row.isFlagged, isTrue, reason: "the other client's star");
    expect(row.srvIsSeen, isFalse);
    expect(row.isSeen, isTrue, reason: 'the queued change still shows');
    await expectConsistent();
  });
}
