// Force resync as mark-and-sweep on JMAP (SYNC-REDESIGN.md §6, phase 6a):
// a folder resync marks a full sync due (an empty resume point), so the
// folder does not adopt the account's global `Email` state; the full sync
// finds the cached rows again by their server id, prunes what its complete
// enumeration did not list (App Log `sync.resync_swept`), and the folder is
// on the incremental path again afterwards.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'helpers/jmap_test_server.dart';
import 'recording_app_log_repository.dart';

const _jmapAccountId = 'u1';
const _mailbox = 'mbox-1';

const _account = Account(
  id: 'jmap-resync',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

void main() {
  final cacheDir = useJmapTestEnv('force_resync_jmap');

  late JmapTestRepos r;
  late RecordingAppLogRepository logs;
  late List<String> serverIds;
  late List<String> methods;

  setUp(() async {
    serverIds = ['e1', 'e2'];
    methods = [];
    logs = RecordingAppLogRepository();
    r = await openJmapTestRepos(
      account: _account,
      cacheDir: cacheDir(),
      appLogger: AppLogger(logs),
      httpClient: jmapFakeServer(
        accountId: _jmapAccountId,
        handle: (call) {
          methods.add(call.method);
          switch (call.method) {
            case 'Email/changes':
              return jmapEmailChangesResponse(
                accountId: _jmapAccountId,
                callId: call.callId,
              );
            case 'Email/query':
              return jmapQueryPage(
                accountId: _jmapAccountId,
                sortedIds: serverIds,
                args: call.args,
                callId: call.callId,
              );
            case 'Email/get':
              return jmapEmailGetResponseFor(
                accountId: _jmapAccountId,
                state: 's0',
                ids: call.ids,
                mailboxId: _mailbox,
                omit: {
                  for (final id in call.ids)
                    if (!serverIds.contains(id)) id,
                },
                callId: call.callId,
              );
          }
          return null;
        },
      ),
    );
    await r.emails.syncEmails(_account.id, _mailbox);
  });
  tearDown(() => r.db.close());

  Future<Email?> rowOf(String jmapId) =>
      (r.db.select(r.db.emails)..where((t) => t.srvJmapId.equals(jmapId)))
          .getSingleOrNull();

  test(
      'a folder resync is a full sync that keeps found rows and sweeps lost '
      'ones, then the folder is incremental again', () async {
    final e1 = (await rowOf('e1'))!;
    expect(await rowOf('e2'), isNotNull);
    // The account's global state, which a folder without a state of its
    // own would adopt (and then only ask for changes).
    await r.db.into(r.db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: _account.id,
            resourceType: 'Email',
            state: 's0',
            syncedAt: DateTime(2026),
          ),
        );
    serverIds.remove('e2');

    await r.emails.clearMailboxForResync(_account.id, _mailbox);
    expect(await jmapStoredSyncState(r.db, 'JMAP:FullSync:$_mailbox'), '{}');
    expect(await rowOf('e2'), isNotNull, reason: 'nothing deleted up front');

    methods.clear();
    await r.emails.syncEmails(_account.id, _mailbox);

    expect(methods, contains('Email/query'), reason: 'a full sync');
    expect((await rowOf('e1'))!.id, e1.id, reason: 'found again in place');
    expect(await rowOf('e2'), isNull, reason: 'swept');
    final swept = [
      for (final row in logs.inserts)
        if (row['event'] == 'sync.resync_swept') row,
    ];
    expect(swept.single['mailboxPath'], _mailbox);
    expect(
      (jsonDecode(swept.single['dataJson']! as String)
          as Map<String, Object?>)['emailIds'],
      hasLength(1),
    );
    expect(await jmapStoredSyncState(r.db, 'JMAP:FullSync:$_mailbox'), isNull);
    expect(await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'), 's0');

    methods.clear();
    await r.emails.syncEmails(_account.id, _mailbox);
    expect(methods, contains('Email/changes'));
    expect(methods, isNot(contains('Email/query')), reason: 'incremental');
  });

  test('the account resync marks a full sync due for every folder', () async {
    await r.db.into(r.db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '${_account.id}:$_mailbox',
            accountId: _account.id,
            path: _mailbox,
            name: 'Inbox',
            srvName: const Value('Inbox'),
          ),
        );

    await r.emails.clearForResync(_account.id);

    expect(await jmapStoredSyncState(r.db, 'JMAP:FullSync:$_mailbox'), '{}');
    expect(await jmapStoredSyncState(r.db, 'JMAP:Email:$_mailbox'), isNull);
    expect(await rowOf('e1'), isNotNull);
  });
}
