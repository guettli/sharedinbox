import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show ImapConnectFn;
import 'package:sharedinbox/data/jmap/jmap_client.dart' show JmapException;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart' show SnoozeSpyImapClient;
import 'recording_app_log_repository.dart';
// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const _jmapAccount = Account(
  id: 'jmap-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

// Builds a mock HTTP client that serves a JMAP session + sequence of
// API responses for each POST to the API URL.
/// [requests], when given, collects every API request body in call order.
http.Client _mockJmap({
  required List<Map<String, dynamic>> apiResponses,
  List<String>? requests,
}) {
  var callIndex = 0;
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'accounts': {
            'acct1': {'name': 'alice@example.com', 'isPersonal': true},
          },
          'primaryAccounts': {
            'urn:ietf:params:jmap:core': 'acct1',
            'urn:ietf:params:jmap:mail': 'acct1',
          },
          'capabilities': {},
          'username': 'alice@example.com',
          'state': 'sess1',
        }),
        200,
      );
    }
    // API call
    requests?.add(req.body);
    final resp = apiResponses[callIndex % apiResponses.length];
    callIndex++;
    return http.Response(jsonEncode(resp), 200);
  });
}

Map<String, dynamic> _mailboxGetResponse({
  required String state,
  required List<Map<String, dynamic>> list,
}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Mailbox/get',
          {'accountId': 'acct1', 'state': state, 'list': list},
          '0',
        ],
      ],
    };

Map<String, dynamic> _mailboxChangesResponse({
  required String oldState,
  required String newState,
  List<String> created = const [],
  List<String> updated = const [],
  List<String> destroyed = const [],
}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Mailbox/changes',
          {
            'accountId': 'acct1',
            'oldState': oldState,
            'newState': newState,
            'hasMoreChanges': false,
            'created': created,
            'updated': updated,
            'destroyed': destroyed,
          },
          '0',
        ],
      ],
    };

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

typedef _Repos = ({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  MailboxRepositoryImpl mailboxes,
  http.Client? httpClient,
});

_Repos _makeRepos({
  http.Client? httpClient,
  ImapConnectFn? imapConnect,
  AppLogger? appLogger,
}) {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: imapConnect ?? _noImapConnect,
    httpClient: httpClient,
    appLogger: appLogger,
  );
  return (
    db: db,
    accounts: accounts,
    mailboxes: mailboxes,
    httpClient: httpClient,
  );
}

/// One flush of [accountId]'s queue, as a sync cycle starts with: the
/// folder ops first (SYNC-REDESIGN.md §7).
Future<void> _flush(
  _Repos r,
  String accountId, {
  ImapConnectFn? imapConnect,
  http.Client? httpClient,
}) =>
    EmailRepositoryImpl(
      r.db,
      r.accounts,
      imapConnect: imapConnect ?? _noImapConnect,
      httpClient: httpClient,
    ).flushPendingChanges(accountId, 'pw');

/// A mailbox sync stored: the server's [name] for the folder at [path].
Future<void> _seedMailbox(
  AppDatabase db,
  String accountId,
  String path,
  String name, {
  String? displayPath,
}) =>
    db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '$accountId:$path',
            accountId: accountId,
            path: path,
            name: name,
            srvName: Value(name),
            displayPath:
                Value(displayPath ?? (accountId == 'acc-1' ? path : name)),
          ),
        );

Map<String, dynamic> _setCreated(Map<String, String> ids) => {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Mailbox/set',
          {
            'accountId': 'acct1',
            'created': {
              for (final e in ids.entries) e.key: {'id': e.value},
            },
          },
          '0',
        ],
      ],
    };

Map<String, dynamic> _setNotCreated(String type, String? description) => {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Mailbox/set',
          {
            'accountId': 'acct1',
            'notCreated': {
              'c0': {
                'type': type,
                if (description != null) 'description': description,
              },
            },
          },
          '0',
        ],
      ],
    };

/// The method of the single call in JMAP request [body].
String _method(String body) =>
    (((jsonDecode(body) as Map)['methodCalls'] as List).single as List)[0]
        as String;

/// The `create` map of the Mailbox/set in request [body].
Map<String, dynamic> _createArgs(String body) {
  final call =
      ((jsonDecode(body) as Map)['methodCalls'] as List).single as List;
  expect(call[0], 'Mailbox/set');
  return (call[1] as Map<String, dynamic>)['create'] as Map<String, dynamic>;
}

/// Queued changes that are not acked.
Future<List<PendingChangeRow>> _unsettled(AppDatabase db) =>
    (db.select(db.pendingChanges)..where((t) => t.state.equals('acked').not()))
        .get();

/// In-memory [AppLogRepository] that records inserted entries so tests can
/// assert what was logged.
class _RecordingAppLogRepository extends RecordingAppLogRepository {
  List<({AppLogLevel level, String event, String? mailboxPath})> get entries =>
      [
        for (final r in rows)
          (level: r.level, event: r.event, mailboxPath: r.mailboxPath),
      ];
}

/// Fake IMAP client that lists one mailbox but fails every STATUS request,
/// exercising the count-computation failure path (#498).
class _StatusFailsImapClient extends SnoozeSpyImapClient {
  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      [
        imap.Mailbox(
          encodedName: 'foo',
          encodedPath: 'foo',
          pathSeparator: '/',
          flags: const [],
        ),
      ];

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox mailbox,
    List<imap.StatusFlags> flags,
  ) async =>
      throw Exception('STATUS failed');

  @override
  Future<dynamic> logout() async {}
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('MailboxRepositoryImpl', () {
    test('observeMailboxes emits empty list initially', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes, isEmpty);
    });

    test('observeMailboxes reflects inserted rows ordered by path', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      for (final (path, name) in [
        ('Sent', 'Sent'),
        ('INBOX', 'Inbox'),
        ('Drafts', 'Drafts'),
      ]) {
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-1:$path',
                accountId: 'acc-1',
                path: path,
                name: name,
              ),
            );
      }

      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes.map((m) => m.path).toList(), [
        'Drafts',
        'INBOX',
        'Sent',
      ]);
    });

    test(
      'observeMailboxes only returns mailboxes for the given account',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        const other = Account(
          id: 'acc-2',
          displayName: 'Bob',
          email: 'bob@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );
        await r.accounts.addAccount(other, 'pw2');

        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-1:INBOX',
                accountId: 'acc-1',
                path: 'INBOX',
                name: 'Inbox',
              ),
            );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-2:INBOX',
                accountId: 'acc-2',
                path: 'INBOX',
                name: 'Inbox',
              ),
            );

        final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
        expect(mailboxes, hasLength(1));
        expect(mailboxes.first.id, 'acc-1:INBOX');
      },
    );

    test('observeMailboxes maps unread/total counts', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-1:INBOX',
              accountId: 'acc-1',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: const Value(5),
              totalCount: const Value(42),
            ),
          );

      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes.first.unreadCount, 5);
      expect(mailboxes.first.totalCount, 42);
    });

    test('syncMailboxes propagates IMAP error', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      expect(
        () => r.mailboxes.syncMailboxes('acc-1'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test(
      'syncMailboxes logs a warning when STATUS count computation fails (#498)',
      () async {
        final logs = _RecordingAppLogRepository();
        final r = _makeRepos(
          imapConnect: (_, __, ___) async => _StatusFailsImapClient(),
          appLogger: AppLogger(logs),
        );
        await r.accounts.addAccount(_account, 'pw');

        await r.mailboxes.syncMailboxes('acc-1');

        // The mailbox is still persisted, falling back to a zero count…
        final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
        expect(mailboxes.single.totalCount, 0);
        // …and the silent failure is recorded in the App Log.
        expect(
          logs.entries,
          contains(
            (
              level: AppLogLevel.warn,
              event: 'mailbox_count_failed',
              mailboxPath: 'foo',
            ),
          ),
        );
      },
    );

    group('JMAP syncMailboxes', () {
      test('full sync: upserts all mailboxes and persists state', () async {
        final r = _makeRepos(
          httpClient: _mockJmap(
            apiResponses: [
              _mailboxGetResponse(
                state: 'st1',
                list: [
                  {
                    'id': 'mbx1',
                    'name': 'Inbox',
                    'unreadEmails': 3,
                    'totalEmails': 10,
                  },
                  {
                    'id': 'mbx2',
                    'name': 'Sent',
                    'unreadEmails': 0,
                    'totalEmails': 5,
                  },
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.mailboxes.syncMailboxes('jmap-1');

        final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
        expect(mailboxes, hasLength(2));
        expect(mailboxes.map((m) => m.name).toSet(), {'Inbox', 'Sent'});
        expect(mailboxes.firstWhere((m) => m.name == 'Inbox').unreadCount, 3);

        // state persisted in sync_state
        final state = await r.db.select(r.db.syncStates).get();
        expect(state, hasLength(1));
        expect(state.first.state, 'st1');
      });

      test(
        'full sync computes hierarchical displayPath from parentId chain',
        () async {
          // Three mailboxes returned by the server: Archive (root), 2026
          // (child of Archive), Q1 (child of 2026). The displayPath must
          // walk the parentId chain so the UI can show "Archive/2026/Q1"
          // instead of the opaque one-char server IDs.
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxGetResponse(
                  state: 'st1',
                  list: [
                    {'id': 'a', 'name': 'Archive'},
                    {'id': 'b', 'name': '2026', 'parentId': 'a'},
                    {'id': 'c', 'name': 'Q1', 'parentId': 'b'},
                  ],
                ),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await r.mailboxes.syncMailboxes('jmap-1');

          final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
          final byPath = {for (final m in mailboxes) m.path: m};
          expect(byPath['a']!.displayPath, 'Archive');
          expect(byPath['b']!.displayPath, 'Archive/2026');
          expect(byPath['c']!.displayPath, 'Archive/2026/Q1');
          // parent chain preserved so a later rename can rebuild children.
          expect(byPath['a']!.parentId, isNull);
          expect(byPath['b']!.parentId, 'a');
          expect(byPath['c']!.parentId, 'b');
          // path still holds the opaque server ID (unchanged from before v47).
          expect(byPath['a']!.path, 'a');
        },
      );

      test(
        'renaming a parent updates every descendant displayPath',
        () async {
          // First sync seeds the tree, then Mailbox/changes reports that "a"
          // was renamed from "Archive" → "Archiv"; the incremental fetch
          // only returns "a", but the previously-synced children must have
          // their displayPath rebuilt to reflect the new parent name.
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxGetResponse(
                  state: 'st1',
                  list: [
                    {'id': 'a', 'name': 'Archive'},
                    {'id': 'b', 'name': '2026', 'parentId': 'a'},
                  ],
                ),
                _mailboxChangesResponse(
                  oldState: 'st1',
                  newState: 'st2',
                  updated: ['a'],
                ),
                _mailboxGetResponse(
                  state: 'st2',
                  list: [
                    {'id': 'a', 'name': 'Archiv'},
                  ],
                ),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await r.mailboxes.syncMailboxes('jmap-1');
          await r.mailboxes.syncMailboxes('jmap-1');

          final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
          final byPath = {for (final m in mailboxes) m.path: m};
          expect(byPath['a']!.displayPath, 'Archiv');
          expect(byPath['b']!.displayPath, 'Archiv/2026');
        },
      );

      test('incremental sync: applies created, updated, destroyed', () async {
        final r = _makeRepos(
          httpClient: _mockJmap(
            apiResponses: [
              // First call: Mailbox/changes
              _mailboxChangesResponse(
                oldState: 'st1',
                newState: 'st2',
                created: ['mbx3'],
                updated: ['mbx1'],
                destroyed: ['mbx2'],
              ),
              // Second call: Mailbox/get for created + updated
              _mailboxGetResponse(
                state: 'st2',
                list: [
                  {
                    'id': 'mbx1',
                    'name': 'Inbox',
                    'unreadEmails': 1,
                    'totalEmails': 8,
                  },
                  {
                    'id': 'mbx3',
                    'name': 'Archive',
                    'unreadEmails': 0,
                    'totalEmails': 2,
                  },
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');

        // Pre-populate DB with existing mailboxes and state
        await r.db.into(r.db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx1',
                accountId: 'jmap-1',
                path: 'mbx1',
                name: 'Inbox',
                unreadCount: const Value(5),
                totalCount: const Value(10),
              ),
            );
        await r.db.into(r.db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx2',
                accountId: 'jmap-1',
                path: 'mbx2',
                name: 'Sent',
              ),
            );
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Mailbox',
                state: 'st1',
                syncedAt: DateTime.now(),
              ),
            );

        await r.mailboxes.syncMailboxes('jmap-1');

        final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
        expect(mailboxes.map((m) => m.name).toSet(), {'Inbox', 'Archive'});
        expect(mailboxes.firstWhere((m) => m.name == 'Inbox').unreadCount, 1);

        final state = await r.db.select(r.db.syncStates).get();
        expect(state.first.state, 'st2');
      });

      test('incremental sync with no changes updates state only', () async {
        final r = _makeRepos(
          httpClient: _mockJmap(
            apiResponses: [
              _mailboxChangesResponse(oldState: 'st1', newState: 'st1'),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Mailbox',
                state: 'st1',
                syncedAt: DateTime.now(),
              ),
            );

        await r.mailboxes.syncMailboxes('jmap-1');

        final state = await r.db.select(r.db.syncStates).get();
        expect(state.first.state, 'st1');
      });

      test(
        'incremental sync fetches an uncached parent so displayPath is not '
        'the opaque id (#605)',
        () async {
          // Only the child "b" changed; its parent "a" was never cached. The
          // sync must follow the parentId and fetch "a" so "b" renders as
          // "Archive/2026" instead of leaking the opaque id as "a/2026".
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxChangesResponse(
                  oldState: 'st1',
                  newState: 'st2',
                  updated: ['b'],
                ),
                _mailboxGetResponse(
                  state: 'st2',
                  list: [
                    {
                      'id': 'b',
                      'name': '2026',
                      'parentId': 'a',
                      'unreadEmails': 0,
                      'totalEmails': 3,
                    },
                  ],
                ),
                _mailboxGetResponse(
                  state: 'st2',
                  list: [
                    {'id': 'a', 'name': 'Archive'},
                  ],
                ),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await r.db.into(r.db.syncStates).insertOnConflictUpdate(
                SyncStatesCompanion.insert(
                  accountId: 'jmap-1',
                  resourceType: 'Mailbox',
                  state: 'st1',
                  syncedAt: DateTime.now(),
                ),
              );

          await r.mailboxes.syncMailboxes('jmap-1');

          final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
          final byPath = {for (final m in mailboxes) m.path: m};
          expect(byPath['a']!.name, 'Archive');
          expect(byPath['b']!.displayPath, 'Archive/2026');
          // No mailbox's displayPath may be the raw opaque server id.
          for (final m in mailboxes) {
            expect(m.displayPath.split('/'), isNot(contains(m.path)));
          }
        },
      );

      test(
        'incremental sync truncates rather than embedding an unresolvable '
        'parent id (#605)',
        () async {
          // The parent "a" was concurrently deleted, so Mailbox/get returns it
          // in neither response. "b" must render as "2026" — a shorter but
          // honest path — never "a/2026", and the fetch must not loop forever.
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxChangesResponse(
                  oldState: 'st1',
                  newState: 'st2',
                  updated: ['b'],
                ),
                _mailboxGetResponse(
                  state: 'st2',
                  list: [
                    {
                      'id': 'b',
                      'name': '2026',
                      'parentId': 'a',
                      'unreadEmails': 0,
                      'totalEmails': 3,
                    },
                  ],
                ),
                _mailboxGetResponse(state: 'st2', list: []),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await r.db.into(r.db.syncStates).insertOnConflictUpdate(
                SyncStatesCompanion.insert(
                  accountId: 'jmap-1',
                  resourceType: 'Mailbox',
                  state: 'st1',
                  syncedAt: DateTime.now(),
                ),
              );

          await r.mailboxes.syncMailboxes('jmap-1');

          final mailboxes = await r.mailboxes.observeMailboxes('jmap-1').first;
          final byPath = {for (final m in mailboxes) m.path: m};
          expect(byPath['b']!.displayPath, '2026');
        },
      );

      test('syncMailboxes throws when JMAP account has no jmapUrl', () async {
        const noUrlAccount = Account(
          id: 'jmap-no-url',
          displayName: 'NoUrl',
          email: 'nourl@example.com',
          type: AccountType.jmap,
        );
        final r = _makeRepos();
        await r.accounts.addAccount(noUrlAccount, 'pw');
        await expectLater(
          r.mailboxes.syncMailboxes('jmap-no-url'),
          throwsA(isA<Exception>()),
        );
      });

      test(
        'syncMailboxes throws JmapException on API error response',
        () async {
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                {
                  'sessionState': 'sess1',
                  'methodResponses': [
                    [
                      'error',
                      <String, dynamic>{'type': 'serverFail'},
                      '0',
                    ],
                  ],
                },
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await expectLater(
            r.mailboxes.syncMailboxes('jmap-1'),
            throwsA(isA<JmapException>()),
          );
        },
      );
    });

    test('findMailboxByRole returns null when no matching mailbox', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_jmapAccount, 'pw');
      final result = await r.mailboxes.findMailboxByRole('jmap-1', 'inbox');
      expect(result, isNull);
    });

    test('findMailboxByRole returns matching mailbox', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'jmap-1:mbx-inbox',
              accountId: 'jmap-1',
              path: 'INBOX',
              name: 'Inbox',
              role: const Value('inbox'),
            ),
          );

      final result = await r.mailboxes.findMailboxByRole('jmap-1', 'inbox');
      expect(result, isNotNull);
      expect(result!.role, 'inbox');
    });

    // Folder creation is queued (SYNC-REDESIGN.md §7, phase 5a): the folder
    // shows at once, and the flush ([_flush]) creates it on the server.
    group('createMailboxWithRole', () {
      test(
        'IMAP: shows the folder at once and creates it on the server at the '
        'next flush',
        () async {
          final spy = SnoozeSpyImapClient();
          final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
          await r.accounts.addAccount(_account, 'pw');

          final result = await r.mailboxes.createMailboxWithRole(
            'acc-1',
            'Archive',
            'archive',
          );

          // Offline-first: nothing sent yet, the folder is there.
          expect(spy.createdMailbox, isNull);
          expect(result.name, 'Archive');
          expect(result.role, 'archive');
          expect(result.path, 'Archive');
          expect(
            (await r.mailboxes.findMailboxByRole('acc-1', 'archive'))?.name,
            'Archive',
          );

          await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);

          expect(spy.createdMailbox, 'Archive');
          final row = await (r.db.select(r.db.mailboxes)
                ..where((t) => t.path.equals('Archive')))
              .getSingle();
          expect(row.isLocal, isFalse);
          expect(row.srvName, 'Archive');
          expect(await _unsettled(r.db), isEmpty);
        },
      );

      test(
        'JMAP: a role folder is looked up, then created, and gets the '
        "server's id",
        () async {
          final requests = <String>[];
          final r = _makeRepos(
            httpClient: _mockJmap(
              requests: requests,
              apiResponses: [
                _mailboxGetResponse(state: 's1', list: []),
                _setCreated({'c0': 'mbx-archive'}),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');

          final result = await r.mailboxes.createMailboxWithRole(
            'jmap-1',
            'Archive',
            'archive',
          );
          expect(result.name, 'Archive');
          expect(result.role, 'archive');
          // A stand-in until the server names its id.
          expect(result.path, startsWith('~new:'));
          expect(requests, isEmpty);

          await _flush(r, 'jmap-1', httpClient: r.httpClient);

          expect(_method(requests[0]), 'Mailbox/get');
          expect(_createArgs(requests[1]), {
            'c0': {'name': 'Archive', 'role': 'archive'},
          });
          final found =
              await r.mailboxes.findMailboxByRole('jmap-1', 'archive');
          expect(found!.path, 'mbx-archive');
          expect(found.name, 'Archive');
          // The row kept its id: a folder's id is frozen.
          expect(found.id, result.id);
        },
      );

      test(
        'IMAP: creates a subfolder under an existing parent using its '
        'displayPath',
        () async {
          final spy = SnoozeSpyImapClient();
          final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
          await r.accounts.addAccount(_account, 'pw');
          await _seedMailbox(r.db, 'acc-1', 'Archive', 'Archive');

          final result = await r.mailboxes.createMailbox(
            'acc-1',
            '2026',
            parentDisplayPath: 'Archive',
          );
          expect(result.name, '2026');
          expect(result.path, 'Archive/2026');
          expect(result.displayPath, 'Archive/2026');

          await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);
          // Top-level parent without a separator: the server's (LIST) is
          // `/`.
          expect(spy.createdMailbox, 'Archive/2026');
        },
      );

      test(
        'IMAP: reuses "." delimiter when the parent path already uses it',
        () async {
          final spy = _SeparatorSpyImapClient('.');
          final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
          await r.accounts.addAccount(_account, 'pw');
          await _seedMailbox(r.db, 'acc-1', 'INBOX.Work', 'Work');

          final result = await r.mailboxes.createMailbox(
            'acc-1',
            'Tasks',
            parentDisplayPath: 'INBOX.Work',
          );
          expect(result.path, 'INBOX.Work.Tasks');
          // Matches what syncMailboxes stores: the server path as-is.
          expect(result.displayPath, 'INBOX.Work.Tasks');

          await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);
          expect(spy.createdMailbox, 'INBOX.Work.Tasks');
        },
      );

      test(
        'throws when parentDisplayPath is not found locally',
        () async {
          final spy = SnoozeSpyImapClient();
          final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
          await r.accounts.addAccount(_account, 'pw');
          await expectLater(
            r.mailboxes.createMailbox(
              'acc-1',
              '2026',
              parentDisplayPath: 'NoSuchParent',
            ),
            throwsA(isA<Exception>()),
          );
          expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
        },
      );

      test('a folder that is shown already is not queued again', () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await _seedMailbox(r.db, 'acc-1', 'Work', 'Work');
        await expectLater(
          r.mailboxes.createMailbox('acc-1', 'Work'),
          throwsA(isA<MailboxExistsException>()),
        );
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
      });

      test(
        'JMAP: a subfolder of a folder created offline waits for it, and '
        "is created below the parent's server id",
        () async {
          final requests = <String>[];
          final r = _makeRepos(
            httpClient: _mockJmap(
              requests: requests,
              apiResponses: [
                _setCreated({'c0': 'mbx-projects'}),
                _setCreated({'c0': 'mbx-2026'}),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');

          final result =
              await r.mailboxes.createMailbox('jmap-1', 'Projects/2026');
          expect(result.name, '2026');
          expect(result.displayPath, 'Projects/2026');
          final shown = await r.mailboxes.observeMailboxes('jmap-1').first;
          expect(
            shown.map((m) => m.displayPath),
            unorderedEquals(['Projects', 'Projects/2026']),
          );

          await _flush(r, 'jmap-1', httpClient: r.httpClient);

          expect(requests, hasLength(2));
          expect(_createArgs(requests[0]), {
            'c0': {'name': 'Projects'},
          });
          // The parent's create named its server id in the child's.
          expect(_createArgs(requests[1]), {
            'c0': {'name': '2026', 'parentId': 'mbx-projects'},
          });
          final all = await r.mailboxes.observeMailboxes('jmap-1').first;
          expect(
            all.map((m) => (m.path, m.parentId, m.displayPath)),
            unorderedEquals([
              ('mbx-projects', null, 'Projects'),
              ('mbx-2026', 'mbx-projects', 'Projects/2026'),
            ]),
          );
        },
      );

      test('JMAP: reuses a cached ancestor', () async {
        final requests = <String>[];
        final r = _makeRepos(
          httpClient: _mockJmap(
            requests: requests,
            apiResponses: [
              _setCreated({'c0': 'mbx-2027'}),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await _seedMailbox(r.db, 'jmap-1', 'mbx-projects', 'Projects');

        await r.mailboxes.createMailbox('jmap-1', 'Projects/2027');
        await _flush(r, 'jmap-1', httpClient: r.httpClient);

        expect(_createArgs(requests.single), {
          'c0': {'name': '2027', 'parentId': 'mbx-projects'},
        });
      });

      test('JMAP: nests below a chosen parent and puts the role on the leaf',
          () async {
        final requests = <String>[];
        final r = _makeRepos(
          httpClient: _mockJmap(
            requests: requests,
            apiResponses: [
              _setCreated({'c0': 'mbx-a'}),
              _mailboxGetResponse(state: 's1', list: []),
              _setCreated({'c0': 'mbx-b'}),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await _seedMailbox(r.db, 'jmap-1', 'mbx-parent', 'Archive');

        final result = await r.mailboxes.createMailboxWithRole(
          'jmap-1',
          'A/B',
          'archive',
          parentDisplayPath: 'Archive',
        );
        expect(result.displayPath, 'Archive/A/B');
        expect(result.role, 'archive');

        await _flush(r, 'jmap-1', httpClient: r.httpClient);
        expect(_createArgs(requests[0]), {
          'c0': {'name': 'A', 'parentId': 'mbx-parent'},
        });
        expect(_createArgs(requests[2]), {
          'c0': {'name': 'B', 'parentId': 'mbx-a', 'role': 'archive'},
        });
      });

      for (final bad in ['a//b', '/a', 'a/', ' / ']) {
        test('rejects "$bad" before queueing anything', () async {
          final r = _makeRepos();
          await r.accounts.addAccount(_jmapAccount, 'pw');
          await expectLater(
            r.mailboxes.createMailbox('jmap-1', bad),
            throwsA(isA<ArgumentError>()),
          );
          expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
        });
      }

      for (final sep in ['/', '.']) {
        test(
          'IMAP: joins the levels with the server delimiter "$sep" (a wrong '
          'guess is corrected by the ack) and caches the ancestor',
          () async {
            final spy = _SeparatorSpyImapClient(sep);
            final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
            await r.accounts.addAccount(_account, 'pw');

            final local = await r.mailboxes.createMailbox(
              'acc-1',
              'Projects/2026',
            );
            // Nothing cached says otherwise: `/` is guessed.
            expect(local.path, 'Projects/2026');

            await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);

            final leafPath = 'Projects${sep}2026';
            expect(spy.createdMailbox, leafPath);
            final all = await r.mailboxes.observeMailboxes('acc-1').first;
            final leaf = all.singleWhere((m) => m.name == '2026');
            expect(leaf.path, leafPath);
            expect(leaf.id, local.id);
            // IMAP sync stores displayPath = server path; match it.
            expect(leaf.displayPath, leafPath);
            final projects = all.singleWhere((m) => m.path == 'Projects');
            expect(projects.displayPath, 'Projects');
          },
        );
      }

      test(
        'JMAP: a level the server refuses fails, hides the folder and fails '
        'its subfolders; the levels created before stay',
        () async {
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _setCreated({'c0': 'mbx-projects'}),
                _setNotCreated('invalidProperties', 'name too long'),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');

          await r.mailboxes.createMailbox('jmap-1', 'Projects/2026/Q1');
          await _flush(r, 'jmap-1', httpClient: r.httpClient);

          final all = await r.mailboxes.observeMailboxes('jmap-1').first;
          expect(all.map((m) => (m.path, m.displayPath, m.parentId)), [
            ('mbx-projects', 'Projects', null),
          ]);
          final changes = await (r.db.select(r.db.pendingChanges)
                ..where((t) => t.state.equals('failed'))
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get();
          expect(changes, hasLength(2));
          expect(
            changes.first.lastError,
            contains('(invalidProperties: name too long)'),
          );
          expect(
            changes.last.lastError,
            contains('"2026" could not be created'),
          );
        },
      );

      test(
        'JMAP: a refused role folder is a failed change, not found by role',
        () async {
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxGetResponse(state: 's1', list: []),
                _setNotCreated('serverFail', null),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');

          await r.mailboxes
              .createMailboxWithRole('jmap-1', 'Archive', 'archive');
          await _flush(r, 'jmap-1', httpClient: r.httpClient);

          expect(
            await r.mailboxes.findMailboxByRole('jmap-1', 'archive'),
            isNull,
          );
          final change = await r.db.select(r.db.pendingChanges).getSingle();
          expect(change.state, 'failed');
          expect(change.changeType, 'create_mailbox');
        },
      );
    });

    group('rename / delete (IMAP, non-ASCII names)', () {
      test(
        'IMAP: the new name shows at once; the flush RENAMEs, sending the '
        'source folder in modified UTF-7 (#633)',
        () async {
          final spy = SnoozeSpyImapClient();
          final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
          await r.accounts.addAccount(_account, 'pw');
          await _seedMailbox(
            r.db,
            'acc-1',
            'Geschäftsführer',
            'Geschäftsführer',
          );

          final renamed = await r.mailboxes
              .renameMailbox('acc-1', 'Geschäftsführer', 'Chef');
          expect(
            (renamed.name, renamed.displayPath, renamed.path),
            ('Chef', 'Chef', 'Geschäftsführer'),
          );
          expect(spy.renamedFromEncodedPath, isNull);

          await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);

          expect(spy.renamedFromEncodedPath, 'Gesch&AOQ-ftsf&APw-hrer');
          expect(spy.renamedToName, 'Chef');
          final row =
              (await r.mailboxes.observeMailboxes('acc-1').first).single;
          expect((row.id, row.path, row.name), (renamed.id, 'Chef', 'Chef'));
        },
      );

      test('IMAP: an acked RENAME moves the server location of its mail',
          () async {
        final spy = SnoozeSpyImapClient();
        final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
        final db = r.db;
        await r.accounts.addAccount(_account, 'pw');
        await _seedMailbox(db, 'acc-1', 'Old', 'Old');
        Future<void> email(
          String id,
          String shownIn,
          String srvPath,
          int uid,
        ) =>
            db.into(db.emails).insert(
                  EmailsCompanion.insert(
                    id: id,
                    accountId: 'acc-1',
                    mailboxPath: shownIn,
                    uid: uid,
                    receivedAt: DateTime(2026),
                    srvMailboxPath: Value(srvPath),
                    srvUid: Value(uid),
                    srvUidValidity: const Value(7),
                  ),
                );
        await email('acc-1:Old:5', 'Old', 'Old', 5);
        // Shown in Archive behind a queued move (stuck, not due: this flush
        // leaves it); the server has it in Old.
        await email('acc-1:Old:6', 'Archive', 'Old', 6);
        await db.into(db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: 'acc-1:Old:6',
                changeType: 'move',
                payload: jsonEncode({
                  'uid': 6,
                  'mailboxPath': 'Old',
                  'dest': 'Archive',
                }),
                createdAt: DateTime(2026),
                state: const Value('stuck'),
                leaseUntil: Value(DateTime(2099)),
              ),
            );
        await EmailStateWriter(db).refold('acc-1:Old:6');
        // A stale row still recording UID 6 in a "Chef" that did not exist.
        await email('acc-1:Chef:6', 'Chef', 'Chef', 6);

        await r.mailboxes.renameMailbox('acc-1', 'Old', 'Chef');
        // Nothing moved before the server renamed the folder.
        expect(
          (await (db.select(db.emails)
                    ..where((t) => t.id.equals('acc-1:Old:5')))
                  .getSingle())
              .srvMailboxPath,
          'Old',
        );
        await _flush(r, 'acc-1', imapConnect: (_, __, ___) async => spy);

        final rows = {
          for (final e in await db.select(db.emails).get())
            e.id: (e.mailboxPath, e.srvMailboxPath, e.srvUid),
        };
        expect(rows['acc-1:Old:5'], ('Chef', 'Chef', 5));
        expect(rows['acc-1:Old:6'], ('Archive', 'Chef', 6));
        // It gives the location up (its UID); the folder it was in stays.
        expect(rows['acc-1:Chef:6'], ('Chef', 'Chef', null));
        // The queued move's source follows the rename too.
        expect(
          (await (db.select(db.pendingChanges)
                    ..where((t) => t.resourceType.equals('Email')))
                  .getSingle())
              .payload,
          contains('"mailboxPath":"Chef"'),
        );
        expect(
          await MailboxStateWriter(db).consistencyProblems(),
          isEmpty,
        );
      });

      test(
        'IMAP: DELETE sends the folder in modified UTF-7 (#633)',
        () async {
          final spy = SnoozeSpyImapClient();
          final db = openTestDatabase();
          final accounts = AccountRepositoryImpl(db, MapSecureStorage());
          final mailboxes = MailboxRepositoryImpl(
            db,
            accounts,
            imapConnect: (_, __, ___) async => spy,
          );
          await accounts.addAccount(_account, 'pw');
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:Geschäftsführer',
                  accountId: 'acc-1',
                  path: 'Geschäftsführer',
                  name: 'Geschäftsführer',
                  displayPath: const Value('Geschäftsführer'),
                ),
              );

          await mailboxes.deleteMailbox('acc-1', 'Geschäftsführer');

          expect(spy.deletedEncodedPath, 'Gesch&AOQ-ftsf&APw-hrer');
        },
      );

      test(
        'delete without removeEmails refuses a folder that has mail on the '
        'server (stale "empty" count)',
        () async {
          final spy = SnoozeSpyImapClient()..statusMessages = 1;
          final db = openTestDatabase();
          final accounts = AccountRepositoryImpl(db, MapSecureStorage());
          final mailboxes = MailboxRepositoryImpl(
            db,
            accounts,
            imapConnect: (_, __, ___) async => spy,
          );
          await accounts.addAccount(_account, 'pw');
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:Work',
                  accountId: 'acc-1',
                  path: 'Work',
                  name: 'Work',
                ),
              );

          await expectLater(
            mailboxes.deleteMailbox('acc-1', 'Work'),
            throwsA(isA<Exception>()),
          );
          expect(spy.deletedEncodedPath, isNull);
          expect(await db.select(db.mailboxes).get(), hasLength(1));

          await mailboxes.deleteMailbox('acc-1', 'Work', removeEmails: true);
          expect(spy.deletedEncodedPath, 'Work');
          expect(await db.select(db.mailboxes).get(), isEmpty);
        },
      );
    });

    group('syncMailboxes IMAP reconciles deleted folders', () {
      test(
        'mailbox removed on server is pruned locally along with cached emails',
        () async {
          final db = openTestDatabase();
          final accounts = AccountRepositoryImpl(db, MapSecureStorage());

          // Server only lists INBOX. The locally cached "Old" folder used to
          // exist and now does not, so it must be pruned along with its
          // emails, sync state, and pending changes.
          final fakeClient = _InboxOnlyImapClient();
          final mailboxes = MailboxRepositoryImpl(
            db,
            accounts,
            imapConnect: (_, __, ___) async => fakeClient,
          );
          await accounts.addAccount(_account, 'pw');

          // Pre-seed both mailboxes.
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:INBOX',
                  accountId: 'acc-1',
                  path: 'INBOX',
                  name: 'Inbox',
                ),
              );
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:Old',
                  accountId: 'acc-1',
                  path: 'Old',
                  name: 'Old',
                ),
              );
          // An email + IMAP checkpoint for the now-deleted folder.
          await db.into(db.emails).insert(
                EmailsCompanion.insert(
                  id: 'acc-1:Old:1',
                  accountId: 'acc-1',
                  mailboxPath: 'Old',
                  uid: 1,
                  receivedAt: DateTime.now(),
                ),
              );
          await db.into(db.syncStates).insert(
                SyncStatesCompanion.insert(
                  accountId: 'acc-1',
                  resourceType: 'IMAP:Old',
                  state: jsonEncode({'uidValidity': 1, 'lastUid': 1}),
                  syncedAt: DateTime.now(),
                ),
              );
          // Pending change for the now-deleted folder.
          await db.into(db.pendingChanges).insert(
                PendingChangesCompanion.insert(
                  accountId: 'acc-1',
                  resourceType: 'email',
                  resourceId: 'acc-1:Old:1',
                  changeType: 'flag_seen',
                  payload: jsonEncode({
                    'uid': 1,
                    'mailboxPath': 'Old',
                    'seen': true,
                  }),
                  createdAt: DateTime.now(),
                ),
              );

          await mailboxes.syncMailboxes('acc-1');

          final remaining = await mailboxes.observeMailboxes('acc-1').first;
          expect(remaining.map((m) => m.path).toList(), ['INBOX']);

          final emails = await db.select(db.emails).get();
          expect(emails, isEmpty);

          final states = await db.select(db.syncStates).get();
          expect(states.where((s) => s.resourceType == 'IMAP:Old'), isEmpty);

          // The queued change can no longer apply: kept, but failed.
          final pending = await db.select(db.pendingChanges).getSingle();
          expect(pending.state, 'failed');
          expect(pending.lastError, 'folder removed on the server');
        },
      );
    });

    group('syncMailboxes JMAP reconciles deleted folders', () {
      test(
        'full sync prunes locally cached mailboxes missing from the response',
        () async {
          final r = _makeRepos(
            httpClient: _mockJmap(
              apiResponses: [
                _mailboxGetResponse(
                  state: 'st1',
                  list: [
                    {
                      'id': 'mbx1',
                      'name': 'Inbox',
                      'unreadEmails': 0,
                      'totalEmails': 0,
                    },
                  ],
                ),
              ],
            ),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');

          // Pre-seed two mailboxes; only mbx1 will come back from the server.
          await r.db.into(r.db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'jmap-1:mbx1',
                  accountId: 'jmap-1',
                  path: 'mbx1',
                  name: 'Inbox',
                ),
              );
          await r.db.into(r.db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'jmap-1:mbx-gone',
                  accountId: 'jmap-1',
                  path: 'mbx-gone',
                  name: 'Old',
                ),
              );
          await r.db.into(r.db.emails).insert(
                EmailsCompanion.insert(
                  id: 'jmap-1:e1',
                  accountId: 'jmap-1',
                  mailboxPath: 'mbx-gone',
                  uid: 0,
                  receivedAt: DateTime.now(),
                ),
              );

          await r.mailboxes.syncMailboxes('jmap-1');

          final remaining = await r.mailboxes.observeMailboxes('jmap-1').first;
          expect(remaining.map((m) => m.path).toList(), ['mbx1']);

          final emails = await r.db.select(r.db.emails).get();
          expect(emails, isEmpty);
        },
      );
    });

    group('syncMailboxes IMAP preserves manually-set role', () {
      test(
        'existing role is kept when server returns no special-use flag',
        () async {
          final spy = SnoozeSpyImapClient();
          // Make listMailboxes return a plain folder without \Archive.
          final db = openTestDatabase();
          final accounts = AccountRepositoryImpl(db, MapSecureStorage());

          // Override listMailboxes to return one plain folder.
          final fakeClient = _PlainArchiveImapClient();
          final mailboxes = MailboxRepositoryImpl(
            db,
            accounts,
            imapConnect: (_, __, ___) async => fakeClient,
          );
          await accounts.addAccount(_account, 'pw');

          // Pre-seed the DB with role='archive' (as if user created the folder).
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:Archive',
                  accountId: 'acc-1',
                  path: 'Archive',
                  name: 'Archive',
                  role: const Value('archive'),
                ),
              );

          await mailboxes.syncMailboxes('acc-1');

          final found = await mailboxes.findMailboxByRole('acc-1', 'archive');
          expect(
            found,
            isNotNull,
            reason: 'Manually-set role should be preserved after sync',
          );
          expect(found!.path, 'Archive');
          // Suppress unused warning on spy.
          expect(spy, isNotNull);
        },
      );
    });

    group('syncMailboxes IMAP maps Gmail All Mail to the "all" role', () {
      test(
        'a folder carrying the \\All special-use flag gets role "all"',
        () async {
          final db = openTestDatabase();
          final accounts = AccountRepositoryImpl(db, MapSecureStorage());
          final mailboxes = MailboxRepositoryImpl(
            db,
            accounts,
            imapConnect: (_, __, ___) async => _AllMailImapClient(),
          );
          await accounts.addAccount(_account, 'pw');

          await mailboxes.syncMailboxes('acc-1');

          // The \All flag must be mapped to the "all" role so both protocols
          // have one signal to skip Gmail's All Mail during sync (#691).
          final found = await mailboxes.findMailboxByRole('acc-1', 'all');
          expect(found, isNotNull);
          expect(found!.name, 'All Mail');
        },
      );
    });

    group('rename / delete / move (JMAP)', () {
      Future<
          ({
            AppDatabase db,
            AccountRepositoryImpl accounts,
            MailboxRepositoryImpl mailboxes,
            List<String> requests,
            http.Client client,
          })> setupJmap({
        required Map<String, dynamic> Function() responseFor,
      }) async {
        final requests = <String>[];
        final client = MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(
              jsonEncode({
                'apiUrl': 'https://jmap.example.com/api/',
                'accounts': {
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true},
                },
                'primaryAccounts': {
                  'urn:ietf:params:jmap:core': 'acct1',
                  'urn:ietf:params:jmap:mail': 'acct1',
                },
                'capabilities': {},
                'username': 'alice@example.com',
                'state': 'sess1',
              }),
              200,
            );
          }
          requests.add(req.body);
          return http.Response(jsonEncode(responseFor()), 200);
        });
        final r = _makeRepos(httpClient: client);
        await r.accounts.addAccount(_jmapAccount, 'pw');
        return (
          db: r.db,
          accounts: r.accounts,
          mailboxes: r.mailboxes,
          requests: requests,
          client: client,
        );
      }

      Future<void> flushJmap(
        ({
          AppDatabase db,
          AccountRepositoryImpl accounts,
          MailboxRepositoryImpl mailboxes,
          List<String> requests,
          http.Client client,
        }) r,
      ) =>
          EmailRepositoryImpl(r.db, r.accounts, httpClient: r.client)
              .flushPendingChanges('jmap-1', 'pw');

      Map<String, dynamic> updated() => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'updated': {'mbx-1': null},
                },
                '0',
              ],
            ],
          };

      Map<String, dynamic> notUpdated(String type) => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'notUpdated': {
                    'mbx-1': {'type': type},
                  },
                },
                '0',
              ],
            ],
          };

      test(
          'rename: the new name shows at once; the flush sends a Mailbox/set '
          'update with the name', () async {
        final r = await setupJmap(responseFor: updated);
        await _seedMailbox(r.db, 'jmap-1', 'mbx-1', 'Old');

        final result =
            await r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'New');

        expect(result.name, 'New');
        expect(result.displayPath, 'New');
        expect(r.requests, isEmpty);

        await flushJmap(r);
        expect(r.requests, hasLength(1));
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final call = (body['methodCalls'] as List<dynamic>).first as List;
        final args = call[1] as Map<String, dynamic>;
        final update = args['update'] as Map<String, dynamic>;
        expect((update['mbx-1'] as Map<String, dynamic>)['name'], 'New');
        final row = await (r.db.select(r.db.mailboxes)
              ..where((t) => t.path.equals('mbx-1')))
            .getSingle();
        expect((row.name, row.srvName), ('New', 'New'));
        // Acked until a folder listing confirms it.
        expect(
          (await r.db.select(r.db.pendingChanges).getSingle()).state,
          'acked',
        );
      });

      test('rename: renaming back before the flush queues nothing', () async {
        final r = await setupJmap(responseFor: updated);
        await _seedMailbox(r.db, 'jmap-1', 'mbx-1', 'Old');

        await r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'New');
        final back = await r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'Old');

        expect(back.name, 'Old');
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
      });

      for (final (type, text) in [
        ('alreadyExists', 'a folder with this name already exists'),
        ('forbidden', 'the server does not allow changing this folder'),
      ]) {
        test(
            'rename: a refused rename ($type) becomes a failed change that '
            'reads well, and the old name shows again', () async {
          final r = await setupJmap(responseFor: () => notUpdated(type));
          await _seedMailbox(r.db, 'jmap-1', 'mbx-1', 'Old');

          await r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'Taken');
          await flushJmap(r);

          final change = await r.db.select(r.db.pendingChanges).getSingle();
          expect(change.state, 'failed');
          expect(change.lastError, '$text ($type)');
          final shown = await r.mailboxes.observeMailboxes('jmap-1').first;
          expect(shown.single.name, 'Old');
        });
      }

      test(
          'delete: sends Mailbox/set destroy with onDestroyRemoveEmails and '
          'drops the local rows', () async {
        final r = await setupJmap(
          responseFor: () => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'destroyed': ['mbx-1'],
                },
                '0',
              ],
            ],
          },
        );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-1',
                accountId: 'jmap-1',
                path: 'mbx-1',
                name: 'Doomed',
                displayPath: const Value('Doomed'),
              ),
            );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-inbox',
                accountId: 'jmap-1',
                path: 'mbx-inbox',
                name: 'Inbox',
                displayPath: const Value('Inbox'),
              ),
            );
        for (final (id, box) in [
          ('e-doomed', 'mbx-1'),
          ('e-kept', 'mbx-inbox'),
        ]) {
          await r.db.into(r.db.emails).insert(
                EmailsCompanion.insert(
                  id: 'jmap-1:$id',
                  accountId: 'jmap-1',
                  mailboxPath: box,
                  uid: 0,
                  receivedAt: DateTime.now(),
                ),
              );
          await r.db.into(r.db.threads).insert(
                ThreadsCompanion.insert(
                  id: 't-$id',
                  accountId: 'jmap-1',
                  mailboxPath: box,
                  latestDate: DateTime.now(),
                  latestEmailId: 'jmap-1:$id',
                ),
              );
        }

        await r.mailboxes.deleteMailbox('jmap-1', 'mbx-1', removeEmails: true);

        final surviving = await r.mailboxes.observeMailboxes('jmap-1').first;
        expect(surviving.map((m) => m.path), ['mbx-inbox']);
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final args = (body['methodCalls'] as List<dynamic>).first as List;
        final setArgs = args[1] as Map<String, dynamic>;
        expect(setArgs['destroy'], ['mbx-1']);
        // Without it the server answers mailboxHasEmail for a non-empty
        // folder (RFC 8621 §2.5) and nothing is deleted.
        expect(setArgs['onDestroyRemoveEmails'], isTrue);
        final emails = await r.db.select(r.db.emails).get();
        expect(emails.map((e) => e.id), ['jmap-1:e-kept']);
        final threads = await r.db.select(r.db.threads).get();
        expect(threads.map((t) => t.id), ['t-e-kept']);
      });

      test(
          'delete without removeEmails: no onDestroyRemoveEmails, and the '
          "server's mailboxHasEmail keeps the folder with a readable error",
          () async {
        final r = await setupJmap(
          responseFor: () => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'notDestroyed': {
                    'mbx-1': {'type': 'mailboxHasEmail'},
                  },
                },
                '0',
              ],
            ],
          },
        );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-1',
                accountId: 'jmap-1',
                path: 'mbx-1',
                name: 'Parent',
                displayPath: const Value('Parent'),
              ),
            );

        await expectLater(
          r.mailboxes.deleteMailbox('jmap-1', 'mbx-1'),
          throwsA(
            predicate(
              (e) =>
                  e.toString() ==
                  'Exception: the folder is not empty on the server any more '
                      '— reload the folder list and confirm deleting its mail '
                      '(mailboxHasEmail)',
            ),
          ),
        );
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final args = (body['methodCalls'] as List<dynamic>).first as List;
        expect(
          (args[1] as Map<String, dynamic>)
              .containsKey('onDestroyRemoveEmails'),
          isFalse,
        );
        final surviving = await r.mailboxes.observeMailboxes('jmap-1').first;
        expect(surviving.map((m) => m.path), ['mbx-1']);
      });

      test(
          'move: sends Mailbox/set update with parentId and re-parents locally',
          () async {
        final r = await setupJmap(
          responseFor: () => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'updated': {'mbx-child': null},
                },
                '0',
              ],
            ],
          },
        );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-parent',
                accountId: 'jmap-1',
                path: 'mbx-parent',
                name: 'Parent',
                displayPath: const Value('Parent'),
              ),
            );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-child',
                accountId: 'jmap-1',
                path: 'mbx-child',
                name: 'Child',
                displayPath: const Value('Child'),
              ),
            );

        final result = await r.mailboxes.moveMailbox(
          'jmap-1',
          'mbx-child',
          newParentDisplayPath: 'Parent',
        );

        expect(result.parentId, 'mbx-parent');
        expect(result.displayPath, 'Parent/Child');
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final args = (body['methodCalls'] as List<dynamic>).first as List;
        final update =
            (args[1] as Map<String, dynamic>)['update'] as Map<String, dynamic>;
        expect(
          (update['mbx-child'] as Map<String, dynamic>)['parentId'],
          'mbx-parent',
        );
      });

      test(
          'rename: rejects an empty or slash-bearing name without hitting server',
          () async {
        final r = await setupJmap(
          responseFor: () => {
            'sessionState': 'sess1',
            'methodResponses': [],
          },
        );
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'jmap-1:mbx-1',
                accountId: 'jmap-1',
                path: 'mbx-1',
                name: 'Old',
                displayPath: const Value('Old'),
              ),
            );

        await expectLater(
          r.mailboxes.renameMailbox('jmap-1', 'mbx-1', '  '),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'a/b'),
          throwsA(isA<ArgumentError>()),
        );
        expect(r.requests, isEmpty);
      });
    });
  });
}

/// Fake IMAP client whose `listMailboxes` returns only INBOX. Used to drive
/// the "folder deleted on server" reconciliation tests.
class _InboxOnlyImapClient extends SnoozeSpyImapClient {
  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      [
        imap.Mailbox(
          encodedName: 'INBOX',
          encodedPath: 'INBOX',
          pathSeparator: '/',
          flags: const [imap.MailboxFlag.inbox],
        ),
      ];

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox mailbox,
    List<imap.StatusFlags> flags,
  ) async =>
      mailbox;

  @override
  Future<dynamic> logout() async {}
}

/// Fake IMAP client that lists one mailbox named 'Archive' without any
/// special-use flags, and logs out cleanly.
class _PlainArchiveImapClient extends SnoozeSpyImapClient {
  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      [
        imap.Mailbox(
          encodedName: 'Archive',
          encodedPath: 'Archive',
          pathSeparator: '/',
          flags: [], // No \Archive special-use flag
        ),
      ];

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox mailbox,
    List<imap.StatusFlags> flags,
  ) async =>
      mailbox;

  @override
  Future<dynamic> logout() async {}
}

/// Fake IMAP client that lists Gmail's "All Mail" carrying the RFC 6154 \All
/// special-use flag (as Gmail advertises it), and logs out cleanly.
class _AllMailImapClient extends SnoozeSpyImapClient {
  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      [
        imap.Mailbox(
          encodedName: 'All Mail',
          encodedPath: '[Gmail]/All Mail',
          pathSeparator: '/',
          flags: const [imap.MailboxFlag.all],
        ),
      ];

  @override
  Future<imap.Mailbox> statusMailbox(
    imap.Mailbox mailbox,
    List<imap.StatusFlags> flags,
  ) async =>
      mailbox;

  @override
  Future<dynamic> logout() async {}
}

/// [SnoozeSpyImapClient] whose LIST reports [separator] as the hierarchy
/// delimiter (e.g. `.` like Dovecot/Courier).
class _SeparatorSpyImapClient extends SnoozeSpyImapClient {
  _SeparatorSpyImapClient(this.separator);

  final String separator;

  @override
  List<imap.Mailbox> get listedMailboxes => [
        imap.Mailbox(
          encodedName: 'INBOX',
          encodedPath: 'INBOX',
          pathSeparator: separator,
          flags: [],
        ),
      ];
}
