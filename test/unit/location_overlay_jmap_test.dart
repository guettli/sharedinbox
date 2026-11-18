// The `location` overlay on JMAP (SYNC-REDESIGN.md §2–§5, phase 4a): an
// `Email/get` answer writes the server's mailbox only to `srv_mailbox_path`,
// so a queued (or just sent) move or snooze keeps showing (#1238); an
// `Email/changes` `destroyed` no longer deletes a row the user still has a
// change for, and that change surfaces as failed instead (#1239).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _inbox = 'mbox-1';
const _archive = 'mbox-2';

const _account = Account(
  id: 'jmap-loc',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

void main() {
  final cacheDir = useJmapTestEnv('location_overlay_jmap');

  late JmapTestRepos r;
  // The server's view of e1 (null: destroyed), and what Email/changes
  // reports next.
  late Map<String, bool>? mailboxIds;
  late List<String> changed;
  late List<String> destroyed;
  // Runs after an Email/get answer is fixed and before it is returned.
  FutureOr<void> Function()? beforeGetAnswer;

  setUp(() async {
    mailboxIds = {_inbox: true};
    changed = [];
    destroyed = [];
    beforeGetAnswer = null;
    r = await openJmapTestReposOnIncrementalPath(
      httpClient: jmapFakeServer(
        accountId: _jmapAccountId,
        handle: (call) async {
          switch (call.method) {
            case 'Email/set':
              if (call.args['destroy'] case final List<dynamic> ids) {
                final gone = mailboxIds == null;
                mailboxIds = null;
                return [
                  'Email/set',
                  {
                    'accountId': _jmapAccountId,
                    'newState': 's1',
                    if (!gone) 'destroyed': ids,
                    if (gone)
                      'notDestroyed': {
                        for (final id in ids) id: {'type': 'notFound'},
                      },
                  },
                  call.callId,
                ];
              }
              final update = (call.args['update'] as Map<String, dynamic>)['e1']
                  as Map<String, dynamic>;
              if (mailboxIds == null) {
                return [
                  'Email/set',
                  {
                    'accountId': _jmapAccountId,
                    'newState': 's1',
                    'notUpdated': {
                      'e1': {'type': 'notFound'},
                    },
                  },
                  call.callId,
                ];
              }
              if (update['mailboxIds'] case final Map<String, dynamic> ids) {
                mailboxIds = {for (final id in ids.keys) id: true};
              }
              changed = ['e1'];
              return [
                'Email/set',
                {
                  'accountId': _jmapAccountId,
                  'newState': 's1',
                  'updated': {'e1': null},
                },
                call.callId,
              ];
            case 'Email/changes':
              final updated = changed;
              final gone = destroyed;
              changed = [];
              destroyed = [];
              return jmapEmailChangesResponse(
                accountId: _jmapAccountId,
                updated: updated,
                destroyed: gone,
                callId: call.callId,
              );
            case 'Email/get':
              final ids = mailboxIds;
              final answer = jmapEmailGetResponse(
                accountId: _jmapAccountId,
                state: 's0',
                list: [
                  if (ids != null)
                    jmapEmailObject(id: 'e1', mailboxId: _inbox)
                      ..['mailboxIds'] = {...ids},
                ],
                notFound: [if (ids == null) 'e1'],
                callId: call.callId,
              );
              final hook = beforeGetAnswer;
              beforeGetAnswer = null;
              await hook?.call();
              return answer;
          }
          return null;
        },
      ),
      account: _account,
      cacheDir: cacheDir(),
      mailboxJmapId: _inbox,
      syncState: 's0',
    );
    await insertJmapEmailRow(r.db, _account.id, 'e1', mailboxPath: _inbox);
  });
  tearDown(() => r.db.close());

  const id = 'jmap-loc:e1';
  Future<Email?> row() =>
      (r.db.select(r.db.emails)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
  Future<List<PendingChangeRow>> ops() =>
      r.db.select(r.db.pendingChanges).get();
  Future<void> expectConsistent() async =>
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);
  Future<void> sync() => r.emails.syncEmails(_account.id, _inbox);
  Future<void> flush() => r.emails.flushPendingChanges(_account.id, 'pw');

  group('#1238', () {
    test('an Email/get answer during a queued move keeps the move', () async {
      await r.emails.moveEmail(id, _archive);
      // Another client changed e1 (say, its keywords): Email/changes names
      // it, and Email/get still lists it in the inbox.
      changed = ['e1'];

      await sync();

      final e = (await row())!;
      expect(e.mailboxPath, _archive, reason: 'the queued move still shows');
      expect(e.srvMailboxPath, _inbox);
      expect(e.localMailboxPath, _archive);
      expect((await ops()).single.state, 'pending');
      await expectConsistent();

      await flush();
      await sync();

      expect(mailboxIds, {_archive: true});
      expect((await row())!.mailboxPath, _archive);
      expect(await ops(), isEmpty, reason: 'the read confirmed the move');
      await expectConsistent();
    });

    test('a move sent while an Email/get was on its way is not undone',
        () async {
      changed = ['e1'];
      beforeGetAnswer = () async {
        // The answer (inbox) is fixed; the user moves the mail and the
        // move is applied before the app reads that answer.
        await r.emails.moveEmail(id, _archive);
        await flush();
        expect((await ops()).single.state, 'acked');
      };

      await sync();

      final e = (await row())!;
      expect(e.mailboxPath, _archive);
      expect(
        e.srvMailboxPath,
        _archive,
        reason: 'the ack recorded the move; the older answer was ignored',
      );
      await expectConsistent();
    });

    test('an Email/get answer during a queued snooze keeps the snooze',
        () async {
      final until = DateTime.utc(2027, 1, 15, 8);
      await r.emails.snoozeEmail(id, until);
      changed = ['e1'];

      await sync();

      final e = (await row())!;
      expect(e.mailboxPath, 'Snoozed', reason: 'the queued snooze shows');
      expect(e.srvMailboxPath, _inbox);
      expect(e.snoozedUntil!.isAtSameMomentAs(until), isTrue);
      await expectConsistent();
    });
  });

  test('#1238 a snooze made while an Email/get was on its way keeps showing',
      () async {
    final until = DateTime.utc(2027, 1, 15, 8);
    changed = ['e1'];
    beforeGetAnswer = () => r.emails.snoozeEmail(id, until);

    await sync();

    final e = (await row())!;
    expect(e.mailboxPath, 'Snoozed');
    expect(e.srvMailboxPath, _inbox);
    expect(e.snoozedUntil!.isAtSameMomentAs(until), isTrue);
    await expectConsistent();
  });

  group('#1239', () {
    test(
        'Email/changes destroyed keeps a row with a queued move; the move '
        'then surfaces as failed', () async {
      await r.emails.moveEmail(id, _archive);
      mailboxIds = null;
      destroyed = ['e1'];

      await sync();

      final e = (await row())!;
      expect(e.srvGone, isTrue);
      expect(e.mailboxPath, _archive, reason: 'the queued move still shows');
      expect((await ops()).single.state, 'pending');
      await expectConsistent();

      await flush();

      // The server has no such Email: the row goes (clean-up rule), the
      // failed change stays listed.
      final change = (await ops()).single;
      expect(change.state, 'failed', reason: 'never dropped silently');
      expect(await row(), isNull);
      final failed = await r.emails.observeFailedMutations(_account.id).first;
      expect(failed.single.id, change.id);
      await expectConsistent();
    });

    test('Email/changes destroyed removes a row without a change', () async {
      destroyed = ['e1'];
      mailboxIds = null;

      await sync();

      expect(await row(), isNull);
    });

    test('a notFound from Email/get keeps a row with a queued change',
        () async {
      await r.emails.setFlag(id, flagged: true);
      mailboxIds = null;
      changed = ['e1'];

      await sync();

      final e = (await row())!;
      expect(e.srvGone, isTrue);
      expect(e.mailboxPath, '');
      expect((await ops()).single.state, 'pending');
      await expectConsistent();
    });
  });

  test('a delete for good hides the row until it is confirmed gone', () async {
    await r.emails.deleteEmail(id);

    expect((await row())!.mailboxPath, '');
    expect(await r.emails.getEmail(id), isNull);

    await flush();

    expect(mailboxIds, isNull);
    final e = (await row())!;
    expect(e.srvGone, isTrue);
    expect((await ops()).single.state, 'acked');
    await expectConsistent();

    destroyed = ['e1'];
    await sync();

    expect(await row(), isNull);
    expect(await ops(), isEmpty);
  });

  test('a mail moved by another client follows on srv_mailbox_path', () async {
    mailboxIds = {_archive: true};
    changed = ['e1'];

    await sync();

    final e = (await row())!;
    expect(e.srvMailboxPath, _archive);
    expect(e.mailboxPath, _archive);
    await expectConsistent();
  });
}
