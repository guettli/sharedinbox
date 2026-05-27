import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
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
}) _makeRepos({http.Client? httpClient}) {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    httpClient: httpClient,
  );
  return (db: db, accounts: accounts, mailboxes: mailboxes);
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

        final result = await r.mailboxes
            .createMailboxWithRole('jmap-1', 'Archive', 'archive');

        expect(result.name, 'Archive');
        expect(result.role, 'archive');
        expect(result.path, 'mbx-archive');

        final found = await r.mailboxes.findMailboxByRole('jmap-1', 'archive');
        expect(found, isNotNull);
        expect(found!.name, 'Archive');
      });

      test(
        'JMAP: throws when server returns no created ID',
        () async {
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
        },
      );
    });

    group('syncMailboxes IMAP preserves manually-set role', () {
      test('existing role is kept when server returns no special-use flag',
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
      });
    });
  });
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
