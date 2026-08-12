import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart' show SnoozeSpyImapClient;
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
http.Client _mockJmap({required List<Map<String, dynamic>> apiResponses}) {
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

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  MailboxRepositoryImpl mailboxes,
}) _makeRepos({
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
  return (db: db, accounts: accounts, mailboxes: mailboxes);
}

/// In-memory [AppLogRepository] that records inserted entries so tests can
/// assert what was logged.
class _RecordingAppLogRepository extends NoOpAppLogRepository {
  final List<({AppLogLevel level, String event, String? mailboxPath})> entries =
      [];

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    entries.add((level: level, event: event, mailboxPath: mailboxPath));
    return entries.length;
  }
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

    group('createMailboxWithRole', () {
      test('IMAP: creates mailbox on server and persists with role', () async {
        final spy = SnoozeSpyImapClient();
        final db = openTestDatabase();
        final accounts = AccountRepositoryImpl(db, MapSecureStorage());
        final mailboxes = MailboxRepositoryImpl(
          db,
          accounts,
          imapConnect: (_, __, ___) async => spy,
        );
        await accounts.addAccount(_account, 'pw');

        final result = await mailboxes.createMailboxWithRole(
          'acc-1',
          'Archive',
          'archive',
        );

        expect(spy.createdMailbox, 'Archive');
        expect(result.name, 'Archive');
        expect(result.role, 'archive');
        expect(result.path, 'Archive');

        final found = await mailboxes.findMailboxByRole('acc-1', 'archive');
        expect(found, isNotNull);
        expect(found!.name, 'Archive');
      });

      test('JMAP: creates mailbox on server and persists with role', () async {
        final r = _makeRepos(
          httpClient: _mockJmap(
            apiResponses: [
              {
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'Mailbox/set',
                    {
                      'accountId': 'acct1',
                      'created': {
                        'new-mailbox': {'id': 'mbx-archive'},
                      },
                    },
                    '0',
                  ],
                ],
              },
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
        expect(result.path, 'mbx-archive');

        final found = await r.mailboxes.findMailboxByRole('jmap-1', 'archive');
        expect(found, isNotNull);
        expect(found!.name, 'Archive');
      });

      test(
        'IMAP: creates a subfolder under an existing parent using its '
        'displayPath',
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
          // Pre-seed the parent mailbox in the local cache.
          await db.into(db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'acc-1:Archive',
                  accountId: 'acc-1',
                  path: 'Archive',
                  name: 'Archive',
                  displayPath: const Value('Archive'),
                ),
              );

          final result = await mailboxes.createMailbox(
            'acc-1',
            '2026',
            parentDisplayPath: 'Archive',
          );

          // Delimiter defaulted from the parent's own path (top-level, no
          // `/` or `.`), so the fake server sees the LIST probe and hands
          // back `/` — the new folder is created at Archive/2026.
          expect(spy.createdMailbox, 'Archive/2026');
          expect(result.name, '2026');
          expect(result.path, 'Archive/2026');
          expect(result.displayPath, 'Archive/2026');
        },
      );

      test(
        'IMAP: reuses "." delimiter when the parent path already uses it',
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
                  id: 'acc-1:INBOX.Work',
                  accountId: 'acc-1',
                  path: 'INBOX.Work',
                  name: 'Work',
                  displayPath: const Value('INBOX/Work'),
                ),
              );

          final result = await mailboxes.createMailbox(
            'acc-1',
            'Tasks',
            parentDisplayPath: 'INBOX/Work',
          );

          expect(spy.createdMailbox, 'INBOX.Work.Tasks');
          expect(result.path, 'INBOX.Work.Tasks');
          // displayPath is always joined with `/` for the UI.
          expect(result.displayPath, 'INBOX/Work/Tasks');
        },
      );

      test(
        'throws when parentDisplayPath is not found locally',
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
          await expectLater(
            mailboxes.createMailbox(
              'acc-1',
              '2026',
              parentDisplayPath: 'NoSuchParent',
            ),
            throwsA(isA<Exception>()),
          );
          // Never touched the server.
          expect(spy.createdMailbox, isNull);
        },
      );

      test(
        'JMAP: creates a subfolder with parentId in Mailbox/set',
        () async {
          final requestedBodies = <String>[];
          final r = _makeRepos(
            httpClient: MockClient((req) async {
              if (req.url.path.contains('well-known')) {
                return http.Response(
                  jsonEncode({
                    'apiUrl': 'https://jmap.example.com/api/',
                    'accounts': {
                      'acct1': {
                        'name': 'alice@example.com',
                        'isPersonal': true,
                      },
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
              requestedBodies.add(req.body);
              return http.Response(
                jsonEncode({
                  'sessionState': 'sess1',
                  'methodResponses': [
                    [
                      'Mailbox/set',
                      {
                        'accountId': 'acct1',
                        'created': {
                          'new-mailbox': {'id': 'mbx-child'},
                        },
                      },
                      '0',
                    ],
                  ],
                }),
                200,
              );
            }),
          );
          await r.accounts.addAccount(_jmapAccount, 'pw');
          // Pre-seed the parent mailbox (as if a previous sync had brought
          // it into the cache).
          await r.db.into(r.db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: 'jmap-1:mbx-parent',
                  accountId: 'jmap-1',
                  path: 'mbx-parent',
                  name: 'Archive',
                  displayPath: const Value('Archive'),
                ),
              );

          final result = await r.mailboxes.createMailbox(
            'jmap-1',
            '2026',
            parentDisplayPath: 'Archive',
          );

          expect(result.name, '2026');
          expect(result.path, 'mbx-child');
          expect(result.parentId, 'mbx-parent');
          expect(result.displayPath, 'Archive/2026');

          // The request body must include parentId pointing at the parent's
          // opaque server ID.
          expect(requestedBodies, hasLength(1));
          final body =
              jsonDecode(requestedBodies.first) as Map<String, dynamic>;
          final calls = body['methodCalls'] as List<dynamic>;
          final args = (calls.first as List)[1] as Map<String, dynamic>;
          final create = args['create'] as Map<String, dynamic>;
          final mbx = create['new-mailbox'] as Map<String, dynamic>;
          expect(mbx['parentId'], 'mbx-parent');
        },
      );

      test('JMAP: throws when server returns no created ID', () async {
        final r = _makeRepos(
          httpClient: _mockJmap(
            apiResponses: [
              {
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'Mailbox/set',
                    {
                      'accountId': 'acct1',
                      'created': null,
                      'notCreated': {
                        'new-mailbox': {'type': 'serverFail'},
                      },
                    },
                    '0',
                  ],
                ],
              },
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');

        await expectLater(
          r.mailboxes.createMailboxWithRole('jmap-1', 'Archive', 'archive'),
          throwsA(isA<Exception>()),
        );
      });
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

          final pending = await db.select(db.pendingChanges).get();
          expect(pending, isEmpty);
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

    group('rename / delete / move (JMAP)', () {
      Future<
          ({
            AppDatabase db,
            AccountRepositoryImpl accounts,
            MailboxRepositoryImpl mailboxes,
            List<String> requests,
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
        );
      }

      test('rename: sends Mailbox/set update with name, updates local row',
          () async {
        final r = await setupJmap(
          responseFor: () => {
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

        final result =
            await r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'New');

        expect(result.name, 'New');
        expect(result.displayPath, 'New');
        expect(r.requests, hasLength(1));
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final call = (body['methodCalls'] as List<dynamic>).first as List;
        final args = call[1] as Map<String, dynamic>;
        final update = args['update'] as Map<String, dynamic>;
        expect((update['mbx-1'] as Map<String, dynamic>)['name'], 'New');
      });

      test('delete: sends Mailbox/set destroy and drops the local row',
          () async {
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

        await r.mailboxes.deleteMailbox('jmap-1', 'mbx-1');

        final surviving = await r.mailboxes.observeMailboxes('jmap-1').first;
        expect(surviving, isEmpty);
        final body = jsonDecode(r.requests.first) as Map<String, dynamic>;
        final args = (body['methodCalls'] as List<dynamic>).first as List;
        expect(
          (args[1] as Map<String, dynamic>)['destroy'],
          ['mbx-1'],
        );
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

      test('rename: surfaces server-side notUpdated errors', () async {
        final r = await setupJmap(
          responseFor: () => {
            'sessionState': 'sess1',
            'methodResponses': [
              [
                'Mailbox/set',
                {
                  'accountId': 'acct1',
                  'notUpdated': {
                    'mbx-1': {'type': 'forbidden'},
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
                name: 'Old',
                displayPath: const Value('Old'),
              ),
            );

        await expectLater(
          r.mailboxes.renameMailbox('jmap-1', 'mbx-1', 'New'),
          throwsA(isA<Exception>()),
        );
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
