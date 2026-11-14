import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

import 'db_test_helper.dart';
import 'fake_imap.dart';
import 'recording_app_log_repository.dart';

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

  /// Every API request body, in order.
  final bodies = <Map<String, dynamic>>[];

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
      bodies.add(decoded);
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

const _imapAccount = Account(
  id: 'imap1',
  displayName: 'bob',
  email: 'bob@example.com',
);

/// Serves a single fixed [account] and no-ops every mutating method; the two
/// concrete stubs differ only in which fixture they expose.
abstract class _SingleAccountRepository implements AccountRepository {
  Account get account;

  @override
  Stream<List<Account>> observeAccounts() => Stream.value([account]);
  @override
  Future<Account?> getAccount(String id) async =>
      id == account.id ? account : null;
  @override
  Future<String> getPassword(String accountId) async => 'pw';
  @override
  Future<void> addAccount(Account a, String p) async {}
  @override
  Future<void> updateAccount(Account a, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
}

class _StubAccounts extends _SingleAccountRepository {
  @override
  Account get account => _account;
}

class _StubImapAccounts extends _SingleAccountRepository {
  @override
  Account get account => _imapAccount;
}

/// Fake IMAP client for the notes incremental-sync path. Serves UID searches
/// from [searchResults] and never returns message bodies (the incremental
/// prune test appends no new UIDs).
class _NotesFakeImap extends SelectingFakeImapClient {
  _NotesFakeImap(this.searchResults);
  final Map<String, List<int>> searchResults;

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final hits = searchResults[searchCriteria] ?? const <int>[];
    return imap.SearchImapResult()
      ..matchingSequence = imap.MessageSequence.fromIds(hits, isUid: true);
  }
}

ImapConnectFn _fixedImapConnect(imap.ImapClient client) =>
    (account, username, password) async => client;

/// Flushes fire-and-forget (`unawaited`) log writes scheduled by the repo.
Future<void> _pumpLogs() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Builds a JMAP-backed [NoteRepositoryImpl] wired to a recording logger,
/// returning both so tests can drive the repo and assert on emitted logs.
({NoteRepositoryImpl repo, RecordingAppLogRepository logRepo})
    _jmapRepoWithLogger(
  AppDatabase db,
  http.Client client,
) {
  final logRepo = RecordingAppLogRepository();
  final repo = NoteRepositoryImpl(
    db,
    _StubAccounts(),
    httpClient: client,
    appLogger: AppLogger(logRepo),
  );
  return (repo: repo, logRepo: logRepo);
}

Future<void> _seedImapAccount(AppDatabase db) async {
  await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: _imapAccount.id,
          displayName: _imapAccount.displayName,
          email: _imapAccount.email,
          imapHost: '',
          imapPort: 0,
          imapSsl: false,
          smtpHost: '',
          smtpPort: 0,
          smtpSsl: false,
        ),
      );
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

/// Opens a fresh in-memory test database and seeds it via [seed]. Callers
/// register this in `setUp` so each test starts from a clean database.
Future<AppDatabase> _freshSeededDb(
  Future<void> Function(AppDatabase) seed,
) async {
  final db = openTestDatabase();
  await seed(db);
  return db;
}

/// Seeds a `q-v1`/`e-v1` notes checkpoint, runs one incremental sync that
/// answers with the given queryChanges/changes and fetched [emails], and
/// returns the note ids left in the database afterwards.
Future<Set<String>> _runIncrementalNotesSync(
  AppDatabase db, {
  required List<Map<String, dynamic>> added,
  required List<String> removed,
  required List<String> created,
  required List<String> destroyed,
  required List<Map<String, dynamic>> emails,
}) async {
  await db.into(db.syncStates).insertOnConflictUpdate(
        SyncStatesCompanion.insert(
          accountId: _account.id,
          resourceType: 'notes',
          state: jsonEncode({'queryState': 'q-v1', 'emailState': 'e-v1'}),
          syncedAt: DateTime(2026),
        ),
      );

  final script = _JmapScript([
    _Turn('Mailbox/get', _mailboxGetResponse()),
    _Turn(
      'Email/queryChanges',
      _incrementalResponse(
        newQueryState: 'q-v2',
        added: added,
        removed: removed,
        newEmailState: 'e-v2',
        created: created,
        updated: const [],
        destroyed: destroyed,
      ),
    ),
    _Turn('Email/get', _emailGetResponse(state: 'e-v2', list: emails)),
  ]);

  final repo = NoteRepositoryImpl(
    db,
    _StubAccounts(),
    httpClient: script.build(),
  );

  await repo.syncAllNotes(_account.id);

  final rows = await db.select(db.emailNotes).get();
  return rows.map((r) => r.id).toSet();
}

Map<String, dynamic> _emailQueryIds(List<String> ids) => {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'Email/query',
          {'accountId': _jmapAccountId, 'ids': ids, 'queryState': 'q'},
          '0',
        ],
      ],
    };

Map<String, dynamic> _emailSetResponse(Map<String, dynamic> args) => {
      'sessionState': 'st1',
      'methodResponses': [
        [
          'Email/set',
          {'accountId': _jmapAccountId, ...args},
          '0',
        ],
      ],
    };

/// An IMAP Notes folder in memory: APPEND, UID SEARCH (ALL, `UID n:*`,
/// `HEADER X-SharedInbox-Note-Id "…"`), UID FETCH of the full message, and
/// STORE \Deleted + UID EXPUNGE. No UIDPLUS, so an APPEND answers no UID.
class _NotesServerImap extends FakeImapClient {
  final Map<int, String> raw = {};
  int nextUid = 1;
  int appends = 0;

  /// Runs once, inside the next `UID SEARCH ALL` after its answer is fixed:
  /// a local change landing while the server's listing is in flight.
  Future<void> Function()? beforeAllAnswer;

  int put(String noteId, String messageId, String text) {
    final builder = imap.MessageBuilder()
      ..subject = 'Note'
      ..text = text;
    builder.addHeader('X-SharedInbox-Note-For', messageId);
    builder.addHeader('X-SharedInbox-Note-Id', noteId);
    final uid = nextUid++;
    raw[uid] = builder.buildMimeMessage().renderMessage();
    return uid;
  }

  imap.MimeMessage _parsed(int uid) =>
      imap.MimeMessage.parseFromText(raw[uid]!)..uid = uid;

  @override
  Future<imap.Mailbox> createMailbox(String path) async => fakeMailbox(path);

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async =>
      fakeMailbox(path)..uidValidity = 1;

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final all = raw.keys.toList()..sort();
    var hits = all;
    final header = RegExp(r'^HEADER X-SharedInbox-Note-Id "(.+)"$').firstMatch(
      searchCriteria,
    );
    final range = RegExp(r'^UID (\d+):\*$').firstMatch(searchCriteria);
    if (header != null) {
      hits = [
        for (final uid in all)
          if (_parsed(uid).getHeaderValue('X-SharedInbox-Note-Id')?.trim() ==
              header.group(1))
            uid,
      ];
    }
    if (range != null) {
      final from = int.parse(range.group(1)!);
      hits = all.where((u) => u >= from).toList();
    }
    final result = imap.SearchImapResult()
      ..matchingSequence = imap.MessageSequence.fromIds(hits, isUid: true);
    final hook = beforeAllAnswer;
    if (searchCriteria == 'ALL' && hook != null) {
      beforeAllAnswer = null;
      await hook();
    }
    return result;
  }

  @override
  Future<imap.FetchImapResult> uidFetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) async =>
      imap.FetchImapResult(
        [
          for (final uid in sequence.toList())
            if (raw.containsKey(uid)) _parsed(uid),
        ],
        null,
      );

  @override
  Future<imap.GenericImapResult> appendMessage(
    imap.MimeMessage message, {
    List<String>? flags,
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
    Duration? responseTimeout,
  }) async {
    appends++;
    final uid = nextUid++;
    raw[uid] = message.renderMessage();
    return imap.GenericImapResult();
  }

  final Set<int> _deleted = {};

  @override
  Future<imap.StoreImapResult> uidMarkDeleted(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async {
    _deleted.addAll(sequence.toList());
    return imap.StoreImapResult();
  }

  @override
  Future<imap.Mailbox?> uidExpunge(imap.MessageSequence sequence) async {
    for (final uid in sequence.toList()) {
      if (_deleted.remove(uid)) raw.remove(uid);
    }
    return null;
  }
}

/// Connects to [server], or fails like a device without network.
ImapConnectFn _connectUnless(
  _NotesServerImap server,
  bool Function() offline,
) =>
    (account, username, password) async {
      if (offline()) throw const SocketException('Network is unreachable');
      return server;
    };

void main() {
  setUpAll(configureSqliteForTests);

  group('NoteRepositoryImpl JMAP syncAllNotes', () {
    late AppDatabase db;

    setUp(() async => db = await _freshSeededDb(_seedAccount));
    tearDown(() => db.close());

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
        final ids = await _runIncrementalNotesSync(
          db,
          added: [
            {'id': 'e-new', 'index': 0},
          ],
          removed: const [],
          created: const ['e-new'],
          destroyed: const ['e-old'],
          emails: [
            _noteEmail(
              id: 'e-new',
              noteId: 'n-new',
              messageId: '<m3@ex.com>',
              body: 'third',
            ),
          ],
        );

        expect(
          ids,
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

    test(
      'id listed in both removed and added survives the incremental sync',
      () async {
        // Regression for #998: a freshly added note vanished a few seconds
        // later because the server reported its id in both `removed` and
        // `added` of Email/queryChanges (allowed by RFC 8620 §5.6).
        await db.into(db.emailNotes).insert(
              EmailNotesCompanion.insert(
                id: 'n-new',
                accountId: _account.id,
                messageId: '<m1@ex.com>',
                noteText: 'just added',
                serverId: 'e-new',
                createdAt: DateTime(2026),
              ),
            );
        await db.into(db.emailNotes).insert(
              EmailNotesCompanion.insert(
                id: 'n-moved',
                accountId: _account.id,
                messageId: '<m2@ex.com>',
                noteText: 'moved out of Notes',
                serverId: 'e-moved',
                createdAt: DateTime(2026),
              ),
            );
        final ids = await _runIncrementalNotesSync(
          db,
          added: [
            {'id': 'e-new', 'index': 0},
          ],
          removed: const ['e-new', 'e-moved'],
          created: const ['e-new'],
          destroyed: const [],
          emails: [
            _noteEmail(
              id: 'e-new',
              noteId: 'n-new',
              messageId: '<m1@ex.com>',
              body: 'just added',
            ),
          ],
        );

        expect(
          ids,
          {'n-new'},
          reason: 'n-new is re-listed in added so it must stay; '
              'n-moved left the query so it must go',
        );
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

    test('removed note is logged against its mail with emailId', () async {
      // Seed a full-sync checkpoint and two cached notes; one will be
      // destroyed on the next incremental sync.
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'local-e0',
              accountId: _account.id,
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2026),
              messageId: const Value('<m0@ex.com>'),
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
              state: jsonEncode({'queryState': 'q-v1', 'emailState': 'e-v1'}),
              syncedAt: DateTime(2026),
            ),
          );

      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/queryChanges',
          _incrementalResponse(
            newQueryState: 'q-v2',
            added: const [],
            removed: const [],
            newEmailState: 'e-v2',
            created: const [],
            updated: const [],
            destroyed: const ['e-old'],
          ),
        ),
      ]);

      final (:repo, :logRepo) = _jmapRepoWithLogger(db, script.build());

      await repo.syncAllNotes(_account.id);
      await _pumpLogs();

      final removedLog = logRepo.inserts.firstWhere(
        (m) => m['event'] == 'note.sync.pruned_removed',
        orElse: () => {},
      );
      expect(removedLog, isNotEmpty, reason: 'removal should be logged');
      expect(removedLog['emailId'], 'local-e0');
      expect(removedLog['level'], AppLogLevel.warn);
    });
  });

  group('NoteRepositoryImpl IMAP prune-by-serverId', () {
    late AppDatabase db;

    setUp(() async => db = await _freshSeededDb(_seedImapAccount));
    tearDown(() => db.close());

    test('locally-added note with empty serverId survives the prune', () async {
      // Checkpoint from a prior sync (uidValidity 0 matches the fake mailbox),
      // forcing the incremental path that prunes by serverId.
      await db.into(db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: _imapAccount.id,
              resourceType: 'notes',
              state: jsonEncode({'uidValidity': 0, 'lastUid': 10}),
              syncedAt: DateTime(2026),
            ),
          );
      // A: just added on a server without UIDPLUS → serverId ''.
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n-pending',
              accountId: _imapAccount.id,
              messageId: '<a@ex.com>',
              noteText: 'just added',
              serverId: '',
              createdAt: DateTime(2026),
            ),
          );
      // B: reconciled note whose UID is still on the server.
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n-kept',
              accountId: _imapAccount.id,
              messageId: '<b@ex.com>',
              noteText: 'kept',
              serverId: '5',
              createdAt: DateTime(2026),
            ),
          );
      // C: a note whose server message really is gone → should be pruned.
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n-gone',
              accountId: _imapAccount.id,
              messageId: '<c@ex.com>',
              noteText: 'gone',
              serverId: '99',
              createdAt: DateTime(2026),
            ),
          );

      final fake = _NotesFakeImap({
        'UID 11:*': const <int>[],
        'ALL': const [5],
      });
      final repo = NoteRepositoryImpl(
        db,
        _StubImapAccounts(),
        imapConnect: _fixedImapConnect(fake),
      );

      await repo.syncAllNotes(_imapAccount.id);

      final ids =
          (await db.select(db.emailNotes).get()).map((r) => r.id).toSet();
      expect(
        ids,
        {'n-pending', 'n-kept'},
        reason: 'empty-serverId note must survive; stale serverId is pruned',
      );
    });
  });

  group('NoteRepositoryImpl observeNotesForMessages', () {
    late AppDatabase db;

    setUp(() async => db = await _freshSeededDb(_seedAccount));
    tearDown(() => db.close());

    test('returns notes of all related mails, oldest first (#870)', () async {
      Future<void> addRow(String id, String messageId, DateTime at) =>
          db.into(db.emailNotes).insert(
                EmailNotesCompanion.insert(
                  id: id,
                  accountId: _account.id,
                  messageId: messageId,
                  noteText: id,
                  serverId: '',
                  createdAt: at,
                ),
              );
      await addRow('on-reply', '<reply@ex.com>', DateTime(2026, 2));
      await addRow('on-sent', '<sent@ex.com>', DateTime(2026));
      await addRow('unrelated', '<other@ex.com>', DateTime(2026, 3));

      final repo = NoteRepositoryImpl(db, _StubAccounts());
      final notes = await repo.observeNotesForMessages(
        _account.id,
        ['<reply@ex.com>', '<sent@ex.com>'],
      ).first;

      expect(notes.map((n) => n.id), ['on-sent', 'on-reply']);
      expect(
        await repo.observeNotesForMessages(_account.id, const []).first,
        isEmpty,
      );
    });
  });

  group('NoteRepositoryImpl add logging', () {
    late AppDatabase db;

    setUp(() async => db = await _freshSeededDb(_seedAccount));
    tearDown(() => db.close());

    test('addNote logs note.added scoped to the mail via emailId', () async {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'local-e1',
              accountId: _account.id,
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2026),
              messageId: const Value('<msg-1@ex.com>'),
            ),
          );

      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn('Email/query', _emailQueryIds(const [])),
        _Turn('Email/set', {
          'sessionState': 'st1',
          'methodResponses': [
            [
              'Email/set',
              {
                'accountId': _jmapAccountId,
                'created': {
                  'new-note': {'id': 'server-note-1'},
                },
              },
              '0',
            ],
          ],
        }),
      ]);

      final (:repo, :logRepo) = _jmapRepoWithLogger(db, script.build());

      await repo.addNote(_account.id, '<msg-1@ex.com>', 'hello');
      await repo.waitForIdle();
      await _pumpLogs();

      final added = logRepo.inserts.firstWhere(
        (m) => m['event'] == 'note.added',
        orElse: () => {},
      );
      expect(added, isNotEmpty, reason: 'add should be logged');
      expect(added['emailId'], 'local-e1');
      expect(added['level'], AppLogLevel.info);
      expect(
        logRepo.inserts.any((m) => m['event'] == 'note.add.no_server_id'),
        isFalse,
        reason: 'a real server id was returned',
      );
    });
  });

  group('NoteRepositoryImpl offline-first (IMAP)', () {
    late AppDatabase db;
    late _NotesServerImap server;
    var offline = false;
    late NoteRepositoryImpl repo;

    setUp(() async {
      db = await _freshSeededDb(_seedImapAccount);
      server = _NotesServerImap();
      offline = false;
      repo = NoteRepositoryImpl(
        db,
        _StubImapAccounts(),
        imapConnect: _connectUnless(server, () => offline),
      );
    });
    tearDown(() => db.close());

    Future<List<EmailNoteRow>> rows() => db.select(db.emailNotes).get();

    test('a note added offline is kept and pushed by the next sync', () async {
      offline = true;
      await repo.addNote(_imapAccount.id, '<m1@ex.com>', 'call back');
      await repo.waitForIdle();

      final shown =
          await repo.observeNotes(_imapAccount.id, '<m1@ex.com>').first;
      expect(shown.single.noteText, 'call back');
      expect(shown.single.pendingUpload, isTrue);
      expect(server.raw, isEmpty);

      offline = false;
      await repo.syncAllNotes(_imapAccount.id);

      expect(server.raw, hasLength(1));
      final row = (await rows()).single;
      expect(row.pendingUpload, isFalse);
      // No UIDPLUS: the UID was found by the note-id header.
      expect(row.serverId, server.raw.keys.single.toString());
      // A second sync neither duplicates nor drops it.
      await repo.syncAllNotes(_imapAccount.id);
      expect(server.raw, hasLength(1));
      expect((await rows()).single.id, row.id);
    });

    test('online, addNote uploads right away', () async {
      await repo.addNote(_imapAccount.id, '<m1@ex.com>', 'now');
      await repo.waitForIdle();
      expect(server.raw, hasLength(1));
      expect((await rows()).single.pendingUpload, isFalse);
    });

    test('a retried upload whose APPEND already landed is not duplicated',
        () async {
      offline = true;
      await repo.addNote(_imapAccount.id, '<m1@ex.com>', 'once');
      await repo.waitForIdle();
      final id = (await rows()).single.id;
      // The APPEND reached the server, but the answer never reached us.
      server.put(id, '<m1@ex.com>', 'once');

      offline = false;
      await repo.syncAllNotes(_imapAccount.id);

      expect(server.raw, hasLength(1));
      expect(server.appends, 0);
      expect((await rows()).single.pendingUpload, isFalse);
    });

    test('a note deleted offline stays hidden and is removed by the next sync',
        () async {
      final uid = server.put('n1', '<m1@ex.com>', 'old');
      await repo.syncAllNotes(_imapAccount.id);
      expect((await rows()).single.serverId, '$uid');

      offline = true;
      await repo.deleteNote('n1');
      await repo.waitForIdle();
      expect(
        await repo.observeNotes(_imapAccount.id, '<m1@ex.com>').first,
        isEmpty,
      );
      expect(server.raw, hasLength(1));

      offline = false;
      await repo.syncAllNotes(_imapAccount.id);

      expect(server.raw, isEmpty);
      expect(await rows(), isEmpty);
    });

    test('a note added and deleted offline never reaches the server', () async {
      offline = true;
      await repo.addNote(_imapAccount.id, '<m1@ex.com>', 'oops');
      await repo.deleteNote((await rows()).single.id);
      await repo.waitForIdle();

      offline = false;
      await repo.syncAllNotes(_imapAccount.id);

      expect(server.appends, 0);
      expect(await rows(), isEmpty);
    });

    test('a note added while sync lists the server is not pruned', () async {
      final uid = server.put('n1', '<m1@ex.com>', 'old');
      await repo.syncAllNotes(_imapAccount.id);
      expect((await rows()).single.serverId, '$uid');

      // A full scan prunes every cached note missing from the server's
      // listing; the add lands right after that listing was made. Its own
      // push waits for this sync to finish.
      await db.delete(db.syncStates).go();
      server.beforeAllAnswer =
          () => repo.addNote(_imapAccount.id, '<m2@ex.com>', 'new');
      await repo.syncAllNotes(_imapAccount.id);
      await repo.waitForIdle();

      expect(server.beforeAllAnswer, isNull, reason: 'race not exercised');
      final notes =
          await repo.observeNotes(_imapAccount.id, '<m2@ex.com>').first;
      expect(notes.single.noteText, 'new');
    });

    test('a note deleted while sync fetches it does not come back', () async {
      server.put('n1', '<m1@ex.com>', 'old');
      await repo.syncAllNotes(_imapAccount.id);
      // A full scan again: SEARCH ALL, then it fetches and stores the bodies.
      // The delete lands in between; its own push waits for this sync.
      await db.delete(db.syncStates).go();
      var hiddenRightAfterSync = false;
      server.beforeAllAnswer = () => repo.deleteNote('n1');
      await repo.syncAllNotes(_imapAccount.id).then((_) async {
        hiddenRightAfterSync =
            (await repo.observeNotes(_imapAccount.id, '<m1@ex.com>').first)
                .isEmpty;
      });

      expect(server.beforeAllAnswer, isNull, reason: 'race not exercised');
      expect(hiddenRightAfterSync, isTrue);
      await repo.waitForIdle();
      expect(server.raw, isEmpty);
      expect(await rows(), isEmpty);
    });
  });

  group('NoteRepositoryImpl offline-first (JMAP)', () {
    late AppDatabase db;

    setUp(() async => db = await _freshSeededDb(_seedAccount));
    tearDown(() => db.close());

    test('a refused upload stays pending and survives the full sync prune',
        () async {
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n-local',
              accountId: _account.id,
              messageId: '<m@ex.com>',
              noteText: 'mine',
              serverId: '',
              createdAt: DateTime(2026),
              pendingUpload: const Value(true),
            ),
          );
      final script = _JmapScript([
        // Push.
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn('Email/query', _emailQueryIds(const [])),
        _Turn(
          'Email/set',
          _emailSetResponse({
            'notCreated': {
              'new-note': {'type': 'overQuota'},
            },
          }),
        ),
        // Pull: full sync, server has no notes.
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: const [],
            queryState: 'q1',
            emailState: 'e1',
            emails: const [],
          ),
        ),
        _Turn('Email/get', _emailGetResponse(state: 'e1', list: const [])),
      ]);
      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );

      await repo.syncAllNotes(_account.id);

      final row = (await db.select(db.emailNotes).get()).single;
      expect(row.id, 'n-local');
      expect(row.pendingUpload, isTrue);
    });

    test('a delete destroys only exact note-id matches', () async {
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n1',
              accountId: _account.id,
              messageId: '<m@ex.com>',
              noteText: 'bye',
              serverId: 'srv-1',
              createdAt: DateTime(2026),
              pendingDelete: const Value(true),
            ),
          );
      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        // The loose header filter also hits another note's copy.
        _Turn('Email/query', {
          'sessionState': 'st1',
          'methodResponses': [
            [
              'Email/query',
              {
                'accountId': _jmapAccountId,
                'ids': ['srv-1', 'srv-9'],
              },
              'q',
            ],
            [
              'Email/get',
              {
                'accountId': _jmapAccountId,
                'list': [
                  {'id': 'srv-1', 'header:X-SharedInbox-Note-Id:asText': ' n1'},
                  {
                    'id': 'srv-9',
                    'header:X-SharedInbox-Note-Id:asText': ' n1-and-more',
                  },
                ],
              },
              'g',
            ],
          ],
        }),
        _Turn(
          'Email/set',
          _emailSetResponse({
            'destroyed': ['srv-1'],
          }),
        ),
        // Pull: full sync, nothing left.
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: const [],
            queryState: 'q1',
            emailState: 'e1',
            emails: const [],
          ),
        ),
        _Turn('Email/get', _emailGetResponse(state: 'e1', list: const [])),
      ]);
      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );

      await repo.syncAllNotes(_account.id);

      final destroy = ((script.bodies[2]['methodCalls'] as List).first
          as List)[1] as Map<String, dynamic>;
      expect(destroy['destroy'], ['srv-1']);
      expect(await db.select(db.emailNotes).get(), isEmpty);
    });

    test('the background isolate pulls but never pushes', () async {
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n-local',
              accountId: _account.id,
              messageId: '<m@ex.com>',
              noteText: 'mine',
              serverId: '',
              createdAt: DateTime(2026),
              pendingUpload: const Value(true),
            ),
          );
      final script = _JmapScript([
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: const [],
            queryState: 'q1',
            emailState: 'e1',
            emails: const [],
          ),
        ),
        _Turn('Email/get', _emailGetResponse(state: 'e1', list: const [])),
      ]);
      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
        pushPending: false,
      );

      await repo.syncAllNotes(_account.id);

      expect(script.cursor, 3, reason: 'only the pull ran');
      expect(
        (await db.select(db.emailNotes).get()).single.pendingUpload,
        isTrue,
      );
    });

    test('a deleted note is destroyed and not revived by the pull', () async {
      await db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'n1',
              accountId: _account.id,
              messageId: '<m@ex.com>',
              noteText: 'bye',
              serverId: 'srv-1',
              createdAt: DateTime(2026),
            ),
          );
      final requests = <String>[];
      final script = _JmapScript([
        // Push: the destroy fails (server busy), so the tombstone stays.
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn('Email/query', _emailQueryIds(const ['srv-1'])),
        _Turn(
          'Email/set',
          _emailSetResponse({
            'notDestroyed': {
              'srv-1': {'type': 'serverUnavailable'},
            },
          }),
        ),
        // Pull: full sync still lists the note.
        _Turn('Mailbox/get', _mailboxGetResponse()),
        _Turn(
          'Email/query',
          _mailboxAndFullQuery(
            ids: const ['srv-1'],
            queryState: 'q1',
            emailState: 'e1',
            emails: const [],
          ),
        ),
        _Turn(
          'Email/get',
          _emailGetResponse(
            state: 'e1',
            list: [
              _noteEmail(
                id: 'srv-1',
                noteId: 'n1',
                messageId: '<m@ex.com>',
                body: 'bye',
              ),
            ],
          ),
        ),
      ]);
      final repo = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        // Offline at delete time: the kicked push cannot connect.
        httpClient: MockClient((req) async {
          requests.add(req.url.toString());
          throw const SocketException('Network is unreachable');
        }),
      );
      await repo.deleteNote('n1');
      await repo.waitForIdle();
      expect(requests, isNotEmpty);
      expect(await repo.observeNotes(_account.id, '<m@ex.com>').first, isEmpty);

      final online = NoteRepositoryImpl(
        db,
        _StubAccounts(),
        httpClient: script.build(),
      );
      await online.syncAllNotes(_account.id);

      expect(
        await online.observeNotes(_account.id, '<m@ex.com>').first,
        isEmpty,
        reason: 'the pull must not bring a pending delete back',
      );
      expect(
        (await db.select(db.emailNotes).get()).single.pendingDelete,
        isTrue,
      );
    });
  });
}
