// Snoozing on a JMAP account that has no Snoozed mailbox yet — every fresh
// account. The optimistic local move parks the row under the placeholder
// path `Snoozed`; the flush must turn that into a real mailbox id before it
// sends `Email/set`, or the server reads `Snoozed` as an id and rejects the
// snooze, which the queue then drops. `snoozed` is not a registered JMAP
// role and Stalwart refuses it, so creation falls back to a plain folder.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'helpers/jmap_test_server.dart';

const _jmapAccountId = 'u1';
const _inbox = 'mbox-inbox';

const _jmapAccount = Account(
  id: 'jmap-snz',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// The server's mailboxes once another client has made a Snoozed folder.
const _withSnoozed = [
  {'id': _inbox, 'name': 'Inbox', 'role': 'inbox', 'parentId': null},
  {'id': 'mbox-old', 'name': 'Snoozed', 'role': null, 'parentId': null},
];

/// A server with only an Inbox that, like Stalwart, rejects the unregistered
/// `snoozed` role. Every call it receives is appended to [calls].
http.Client _server(
  List<JmapCall> calls, {
  List<Map<String, dynamic>> mailboxes = const [
    {'id': _inbox, 'name': 'Inbox', 'role': 'inbox', 'parentId': null},
  ],
  bool rejectAllCreates = false,
}) {
  return jmapFakeServer(
    accountId: _jmapAccountId,
    handle: (call) {
      calls.add(call);
      switch (call.method) {
        case 'Mailbox/get':
          return [
            'Mailbox/get',
            {'accountId': _jmapAccountId, 'state': 'm1', 'list': mailboxes},
            call.callId,
          ];
        case 'Mailbox/set':
          final create = call.args['create'] as Map<String, dynamic>;
          final key = create.keys.single;
          final props = create[key] as Map<String, dynamic>;
          if (rejectAllCreates || props.containsKey('role')) {
            return [
              'Mailbox/set',
              {
                'accountId': _jmapAccountId,
                'notCreated': {
                  key: {
                    'type': 'invalidProperties',
                    'properties': ['role'],
                  },
                },
              },
              call.callId,
            ];
          }
          return [
            'Mailbox/set',
            {
              'accountId': _jmapAccountId,
              'created': {
                key: {'id': 'mbox-snoozed'},
              },
            },
            call.callId,
          ];
        case 'Email/get':
          return jmapEmailGetResponse(
            accountId: _jmapAccountId,
            state: 's1',
            list: [
              for (final id in call.ids)
                {'id': id, 'keywords': <String, dynamic>{}},
            ],
            callId: call.callId,
          );
        case 'Email/set':
          final update = call.args['update'] as Map<String, dynamic>;
          return [
            'Email/set',
            {
              'accountId': _jmapAccountId,
              'updated': {for (final id in update.keys) id: null},
            },
            call.callId,
          ];
      }
      return null;
    },
  );
}

void main() {
  final cacheDir = useJmapTestEnv('jmap_snz_');

  Future<JmapTestRepos> seeded(http.Client client) async {
    final r = await openJmapTestRepos(
      httpClient: client,
      account: _jmapAccount,
      cacheDir: cacheDir(),
    );
    await r.db.into(r.db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '${_jmapAccount.id}:$_inbox',
            accountId: _jmapAccount.id,
            path: _inbox,
            name: 'Inbox',
            role: const Value('inbox'),
          ),
        );
    for (final id in ['e1', 'e2']) {
      await insertJmapEmailRow(r.db, _jmapAccount.id, id, mailboxPath: _inbox);
    }
    await r.db
        .update(r.db.emails)
        .write(const EmailsCompanion(threadId: Value('t1')));
    return r;
  }

  /// Parks [jmapId] under the placeholder, as an offline snooze leaves it.
  Future<void> parkUnderPlaceholder(JmapTestRepos r, String jmapId) async {
    await (r.db.update(r.db.emails)
          ..where((t) => t.id.equals('${_jmapAccount.id}:$jmapId')))
        .write(
      EmailsCompanion(
        mailboxPath: const Value('Snoozed'),
        snoozedUntil: Value(DateTime(2026, 11)),
        snoozedFromMailboxPath: const Value(_inbox),
      ),
    );
    await r.db.into(r.db.threads).insertOnConflictUpdate(
          ThreadsCompanion.insert(
            id: 't1',
            accountId: _jmapAccount.id,
            mailboxPath: 'Snoozed',
            latestDate: DateTime(2026),
            latestEmailId: '${_jmapAccount.id}:$jmapId',
          ),
        );
  }

  Future<void> queueUnsnooze(JmapTestRepos r, String jmapId) =>
      r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _jmapAccount.id,
              resourceType: 'Email',
              resourceId: '${_jmapAccount.id}:$jmapId',
              changeType: 'unsnooze',
              payload: '{"uid":0,"src":"Snoozed","dest":"$_inbox"}',
              createdAt: DateTime.now(),
            ),
          );

  Future<List<String>> threadPaths(JmapTestRepos r) async =>
      (await r.db.select(r.db.threads).get())
          .map((t) => t.mailboxPath)
          .toList();

  List<Map<String, dynamic>> emailSetUpdates(List<JmapCall> calls) => [
        for (final c in calls.where((c) => c.method == 'Email/set'))
          ...(c.args['update'] as Map<String, dynamic>)
              .values
              .cast<Map<String, dynamic>>(),
      ];

  test('the flush creates the Snoozed mailbox and snoozes into its real id',
      () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls));
    final until = DateTime(2026, 10, 23, 18);

    await r.emails.snoozeEmail('${_jmapAccount.id}:e1', until);
    await r.emails.snoozeEmail('${_jmapAccount.id}:e2', until);
    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

    // One mailbox is created — with the role first, then without it after
    // the server refuses the role — and the second snooze reuses it.
    final creates = calls.where((c) => c.method == 'Mailbox/set').toList();
    expect(creates, hasLength(2));
    final updates = emailSetUpdates(calls);
    expect(updates, hasLength(2));
    for (final u in updates) {
      expect(u['mailboxIds/mbox-snoozed'], isTrue);
      expect(u['mailboxIds/$_inbox'], isNull);
      expect(u.containsKey('mailboxIds/Snoozed'), isFalse);
      expect(u.keys.where((k) => k.startsWith('keywords/snz:')), hasLength(1));
    }

    final snoozed = await (r.db.select(r.db.mailboxes)
          ..where((t) => t.path.equals('mbox-snoozed')))
        .getSingle();
    expect(snoozed.name, 'Snoozed');
    final rows = await r.db.select(r.db.emails).get();
    expect(rows.map((e) => e.mailboxPath).toSet(), {'mbox-snoozed'});
    expect(
      await r.emails.isSnoozedMailbox(_jmapAccount.id, 'mbox-snoozed'),
      isTrue,
    );

    await r.db.close();
  });

  test('a Snoozed mailbox the server already has is reused, not recreated',
      () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls, mailboxes: _withSnoozed));

    await r.emails.snoozeEmail('${_jmapAccount.id}:e1', DateTime(2026, 11));
    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(calls.where((c) => c.method == 'Mailbox/set'), isEmpty);
    expect(emailSetUpdates(calls).single['mailboxIds/mbox-old'], isTrue);
    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

    await r.db.close();
  });

  test(
      're-snoozing a mail parked under the placeholder only re-tags it and '
      're-points its rows, thread included', () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls));
    await parkUnderPlaceholder(r, 'e1');

    // Snoozing again from the (placeholder) Snoozed folder: src == dest.
    await r.emails.snoozeEmail('${_jmapAccount.id}:e1', DateTime(2026, 12));
    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    final update = emailSetUpdates(calls).single;
    expect(update.keys.where((k) => k.startsWith('mailboxIds/')), isEmpty);
    expect(
      update.keys.where((k) => k.startsWith('keywords/snz:')),
      hasLength(1),
    );

    final row = await (r.db.select(r.db.emails)
          ..where((t) => t.id.equals('${_jmapAccount.id}:e1')))
        .getSingle();
    expect(row.mailboxPath, 'mbox-snoozed');
    expect(row.snoozedFromMailboxPath, 'mbox-snoozed');
    expect(await threadPaths(r), ['mbox-snoozed']);

    await r.db.close();
  });

  test('placeholder rows are re-pointed when the mailbox is already known',
      () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls));
    await parkUnderPlaceholder(r, 'e1');
    // A mailbox sync learned the Snoozed folder after e1 was parked.
    await r.db.into(r.db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '${_jmapAccount.id}:mbox-known',
            accountId: _jmapAccount.id,
            path: 'mbox-known',
            name: 'Snoozed',
          ),
        );
    await r.db.into(r.db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: _jmapAccount.id,
            resourceType: 'Email',
            resourceId: '${_jmapAccount.id}:e1',
            changeType: 'snooze',
            payload: '{"uid":0,"src":"$_inbox","dest":"Snoozed",'
                '"until":"2026-11-01T00:00:00.000"}',
            createdAt: DateTime.now(),
          ),
        );

    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(calls.where((c) => c.method.startsWith('Mailbox/')), isEmpty);
    expect(emailSetUpdates(calls).single['mailboxIds/mbox-known'], isTrue);
    final rows = await r.db.select(r.db.emails).get();
    expect(
      rows.where((e) => e.mailboxPath == 'Snoozed'),
      isEmpty,
    );
    expect(await threadPaths(r), ['mbox-known']);

    await r.db.close();
  });

  test('a mailbox that cannot be created keeps the snooze queued', () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls, rejectAllCreates: true));

    await r.emails.snoozeEmail('${_jmapAccount.id}:e1', DateTime(2026, 11));
    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(emailSetUpdates(calls), isEmpty);
    final pending = await r.db.select(r.db.pendingChanges).get();
    expect(pending.single.changeType, 'snooze');
    expect(pending.single.attempts, 1);
    expect(pending.single.lastError, contains('Snoozed mailbox'));

    await r.db.close();
  });

  test('an unsnooze from the placeholder never creates a mailbox', () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls));
    await queueUnsnooze(r, 'e1');

    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    expect(calls.where((c) => c.method == 'Mailbox/set'), isEmpty);
    final update = emailSetUpdates(calls).single;
    expect(update['mailboxIds/$_inbox'], isTrue);
    expect(update.keys.where((k) => k.startsWith('mailboxIds/')), hasLength(1));
    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

    await r.db.close();
  });

  test('an unsnooze from the placeholder leaves the server Snoozed mailbox',
      () async {
    final calls = <JmapCall>[];
    final r = await seeded(_server(calls, mailboxes: _withSnoozed));
    await queueUnsnooze(r, 'e1');

    await r.emails.flushPendingChanges(_jmapAccount.id, 'pw');

    final update = emailSetUpdates(calls).single;
    expect(update['mailboxIds/$_inbox'], isTrue);
    expect(update.containsKey('mailboxIds/mbox-old'), isTrue);
    expect(update['mailboxIds/mbox-old'], isNull);

    await r.db.close();
  });
}
