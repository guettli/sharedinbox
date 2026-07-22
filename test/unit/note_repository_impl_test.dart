import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

import 'db_test_helper.dart';

// ── Test doubles ──────────────────────────────────────────────────────────

const _sessionUrl = 'https://jmap.example.com/.well-known/jmap';
const _apiPath = '/api/';
const _jmapAccountId = 'u1';
const _notesMailboxId = 'notes-mb';

/// A single expected round-trip: match by method name in the first call
/// (there may be batched calls in one request), respond with the entire
/// [responseBody] regardless.
class _Turn {
  _Turn(this.matchFirstMethod, this.responseBody);
  final String matchFirstMethod;
  final Map<String, dynamic> responseBody;
}

/// Scripts a JMAP conversation. `.well-known/jmap` gets a stock session,
/// every POST to the API URL consumes the next turn. Fails the test if the
/// method name in the request doesn't match the expected turn.
class _JmapScript {
  _JmapScript(this._turns);
  final List<_Turn> _turns;
  int cursor = 0;

  http.Client build() {
    return MockClient((req) async {
      if (req.url.toString() == _sessionUrl) {
        return http.Response(jsonEncode(_session()), 200);
      }
      if (cursor >= _turns.length) {
        fail(
          'Unexpected extra JMAP request: ${req.body}',
        );
      }
      final turn = _turns[cursor++];
      final decoded = jsonDecode(req.body) as Map<String, dynamic>;
      final firstCall =
          ((decoded['methodCalls'] as List).first as List).first as String;
      expect(
        firstCall,
        turn.matchFirstMethod,
        reason: 'JMAP turn ${cursor - 1} expected $firstCall '
            'but received ${req.body}',
      );
      return http.Response(jsonEncode(turn.responseBody), 200);
    });
  }
}

Map<String, dynamic> _session() => {
      'apiUrl': _apiPath,
      'accounts': {
        _jmapAccountId: {
          'name': 'alice@example.com',
          'isPersonal': true,
          'isReadOnly': false,
          'accountCapabilities': {},
        },
      },
      'primaryAccounts': {
        'urn:ietf:params:jmap:core': _jmapAccountId,
        'urn:ietf:params:jmap:mail': _jmapAccountId,
      },
      'capabilities': {},
      'username': 'alice@example.com',
      'state': 'st1',
    };

Map<String, dynamic> _mailboxGetResponse() => {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'Mailbox/get',
          {
            'accountId': _jmapAccountId,
            'list': [
              {'id': _notesMailboxId, 'name': 'Notes'},
            ],
            'state': 'mb-1',
          },
          '0',
        ],
      ],
    };

Map<String, dynamic> _mailboxAndFullQuery({
  required List<String> ids,
  required String queryState,
  required String emailState,
  required List<Map<String, dynamic>> emails,
}) {
  // Two round trips: Mailbox/get first, then Email/query + Email/get.
  return {
    'sessionState': 'st1',
    'methodResponses': [
      [
        'Email/query',
        {
          'accountId': _jmapAccountId,
          'ids': ids,
          'queryState': queryState,
          'position': 0,
        },
        '0',
      ],
    ],
  };
}

Map<String, dynamic> _emailGetResponse({
  required String state,
  required List<Map<String, dynamic>> list,
}) =>
    {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'Email/get',
          {
            'accountId': _jmapAccountId,
            'state': state,
            'list': list,
            'notFound': <String>[],
          },
          '0',
        ],
      ],
    };

Map<String, dynamic> _incrementalResponse({
  required String newQueryState,
  required List<Map<String, dynamic>> added,
  required List<String> removed,
  required String newEmailState,
  required List<String> created,
  required List<String> updated,
  required List<String> destroyed,
}) =>
    {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'Email/queryChanges',
          {
            'accountId': _jmapAccountId,
            'oldQueryState': 'old-q',
            'newQueryState': newQueryState,
            'added': added,
            'removed': removed,
          },
          '0',
        ],
        [
          'Email/changes',
          {
            'accountId': _jmapAccountId,
            'oldState': 'old-e',
            'newState': newEmailState,
            'created': created,
            'updated': updated,
            'destroyed': destroyed,
          },
          '1',
        ],
      ],
    };

Map<String, dynamic> _cannotCalculateChangesResponse() => {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'error',
          {'type': 'cannotCalculateChanges'},
          '0',
        ],
        [
          'error',
          {'type': 'cannotCalculateChanges'},
          '1',
        ],
      ],
    };

Map<String, dynamic> _noteEmail({
  required String id,
  required String noteId,
  required String messageId,
  required String body,
  String receivedAt = '2026-01-01T12:00:00Z',
}) =>
    {
      'id': id,
      'receivedAt': receivedAt,
      'textBody': [
        {'partId': 'p1', 'type': 'text/plain'},
      ],
      'bodyValues': {
        'p1': {'value': body},
      },
      'header:X-SharedInbox-Note-For:asText': ' $messageId',
      'header:X-SharedInbox-Note-Id:asText': ' $noteId',
    };

const _account = Account(
  id: 'acc1',
  displayName: 'alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: _sessionUrl,
);

class _StubAccounts implements AccountRepository {
  @override
  Stream<List<Account>> observeAccounts() => Stream.value([_account]);
  @override
  Future<Account?> getAccount(String id) async =>
      id == _account.id ? _account : null;
  @override
  Future<String> getPassword(String accountId) async => 'pw';
  @override
  Future<void> addAccount(Account a, String p) async {}
  @override
  Future<void> updateAccount(Account a, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
}

Future<void> _seedAccount(AppDatabase db) async {
  await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: _account.id,
          displayName: _account.displayName,
          email: _account.email,
          imapHost: '',
          imapPort: 0,
          imapSsl: false,
          smtpHost: '',
          smtpPort: 0,
          smtpSsl: false,
        ),
      );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('NoteRepositoryImpl JMAP syncAllNotes', () {
    late AppDatabase db;

    setUp(() async {
      db = openTestDatabase();
      await _seedAccount(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('first sync populates notes and stores queryState + emailState',
        () async {
      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: ['e1', 'e2'],
            queryState: 'q-v1',
            emailState: 'e-v1',
            emails: const [],
          ),
        ),
        _Turn(
          'Email/get',
          _emailGetResponse(
            state: 'e-v1',
            list: [
              _noteEmail(
                id: 'e1',
                noteId: 'n1',
                messageId: '<m1@ex.com>',
                body: 'first',
              ),
              _noteEmail(
                id: 'e2',
                noteId: 'n2',
                messageId: '<m2@ex.com>',
                body: 'second',
              ),
            ],
          ),
        ),
      ]);

      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );

      await repo.syncAllNotes(_account.id);

      final rows = await db.select(db.emailNotes).get();
      expect(rows.map((r) => r.id).toSet(), {'n1', 'n2'});
      expect(rows.firstWhere((r) => r.id == 'n1').noteText, 'first');
      expect(rows.firstWhere((r) => r.id == 'n2').messageId, '<m2@ex.com>');

      final checkpointRow = await (db.select(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(_account.id) &
                  t.resourceType.equals('notes'),
            ))
          .getSingle();
      final checkpoint =
          jsonDecode(checkpointRow.state) as Map<String, dynamic>;
      expect(checkpoint['queryState'], 'q-v1');
      expect(checkpoint['emailState'], 'e-v1');
    });

    test(
      'second sync uses queryChanges/changes and applies added + destroyed',
      () async {
        // Pretend we already ran a full sync.
        await db.into(db.emailNotes).insert(
              EmailNotesCompanion.insert(
                id: 'n-existing',
                accountId: _account.id,
                messageId: '<m0@ex.com>',
                noteText: 'kept',
                serverId: 'e-existing',
                createdAt: DateTime(2026),
              ),
            );
        await db.into(db.emailNotes).insert(
              EmailNotesCompanion.insert(
                id: 'n-old',
                accountId: _account.id,
                messageId: '<m0@ex.com>',
                noteText: 'to be destroyed',
                serverId: 'e-old',
                createdAt: DateTime(2026),
              ),
            );
        await db.into(db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: _account.id,
                resourceType: 'notes',
                state: jsonEncode(
                  {'queryState': 'q-v1', 'emailState': 'e-v1'},
                ),
                syncedAt: DateTime(2026),
              ),
            );

        final script = _JmapScript([
          _Turn('Mailbox/get', _mailboxGetResponse()),
          _Turn(
            'Email/queryChanges',
            _incrementalResponse(
              newQueryState: 'q-v2',
              added: [
                {'id': 'e-new', 'index': 0},
              ],
              removed: const [],
              newEmailState: 'e-v2',
              created: const ['e-new'],
              updated: const [],
              destroyed: const ['e-old'],
            ),
          ),
          _Turn(
            'Email/get',
            _emailGetResponse(
              state: 'e-v2',
              list: [
                _noteEmail(
                  id: 'e-new',
                  noteId: 'n-new',
                  messageId: '<m3@ex.com>',
                  body: 'third',
                ),
              ],
            ),
          ),
        ]);

        final repo = NoteRepositoryImpl(
          db,
          _StubAccounts(),
          httpClient: script.build(),
        );

        await repo.syncAllNotes(_account.id);

        final rows = await db.select(db.emailNotes).get();
        expect(
          rows.map((r) => r.id).toSet(),
          {'n-existing', 'n-new'},
          reason: 'n-old should be gone (destroyed), n-new should be present',
        );

        final checkpointRow = await (db.select(db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(_account.id) &
                    t.resourceType.equals('notes'),
              ))
            .getSingle();
        final checkpoint =
            jsonDecode(checkpointRow.state) as Map<String, dynamic>;
        expect(checkpoint['queryState'], 'q-v2');
        expect(checkpoint['emailState'], 'e-v2');
      },
    );

    test('cannotCalculateChanges falls back to a full sync', () async {
      await db.into(db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: _account.id,
              resourceType: 'notes',
              state: jsonEncode(
                {'queryState': 'q-stale', 'emailState': 'e-stale'},
              ),
              syncedAt: DateTime(2026),
            ),
          );

      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn('Email/queryChanges', _cannotCalculateChangesResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: ['e1'],
            queryState: 'q-fresh',
            emailState: 'e-fresh',
            emails: const [],
          ),
        ),
        _Turn(
          'Email/get',
          _emailGetResponse(
            state: 'e-fresh',
            list: [
              _noteEmail(
                id: 'e1',
                noteId: 'n1',
                messageId: '<m@ex.com>',
                body: 'reseeded',
              ),
            ],
          ),
        ),
      ]);

      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );

      await repo.syncAllNotes(_account.id);

      final rows = await db.select(db.emailNotes).get();
      expect(rows.map((r) => r.id).toList(), ['n1']);
      expect(rows.single.noteText, 'reseeded');

      final checkpointRow = await (db.select(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(_account.id) &
                  t.resourceType.equals('notes'),
            ))
          .getSingle();
      final checkpoint =
          jsonDecode(checkpointRow.state) as Map<String, dynamic>;
      expect(checkpoint['queryState'], 'q-fresh');
      expect(checkpoint['emailState'], 'e-fresh');
    });

    test('missing Notes mailbox clears local notes and checkpoint', () async {
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'stale',
              accountId: _account.id,
              messageId: '<m@ex.com>',
              noteText: 'orphan',
              serverId: 'e-x',
              createdAt: DateTime(2026),
            ),
          );
      await db.into(db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: _account.id,
              resourceType: 'notes',
              state: jsonEncode({'queryState': 'q', 'emailState': 'e'}),
              syncedAt: DateTime(2026),
            ),
          );

      final script = _JmapScript([
        _Turn('Mailbox/get', {
          'sessionState': 'st1',
          'methodResponses': [
            [
              'Mailbox/get',
              {'accountId': _jmapAccountId, 'list': [], 'state': 'mb-1'},
              '0',
            ],
          ],
        }),
      ]);

      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );

      await repo.syncAllNotes(_account.id);

      final rows = await db.select(db.emailNotes).get();
      expect(rows, isEmpty);
      final checkpoint = await (db.select(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(_account.id) &
                  t.resourceType.equals('notes'),
            ))
          .getSingleOrNull();
      expect(checkpoint, isNull);
    });
  });
}
