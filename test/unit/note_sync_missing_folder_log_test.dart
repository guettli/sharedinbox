import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

import 'db_test_helper.dart';
import 'fake_imap.dart';
import 'helpers/fake_account_repository.dart';
import 'helpers/jmap_test_server.dart';

const _accountId = 'acct-notes-log';
const _sentinelEvent = 'test.sentinel';

/// Note sync runs every cycle and every App Log row is persisted, so a cycle
/// where nothing changed — no Notes folder (the default on most servers), or
/// an incremental scan with no new or removed notes — must log nothing.
/// Only a sync that actually changed cached state is worth a row.
void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late AppLogger logger;

  setUp(() async {
    db = await openTestDatabaseWithAccounts([_accountId]);
    logger = AppLogger(AppLogRepositoryImpl(db));
  });
  tearDown(() => db.close());

  NoteRepositoryImpl imapRepo(imap.ImapClient client) => NoteRepositoryImpl(
        db,
        FakeAccountRepository([
          const Account(id: _accountId, displayName: 'a', email: 'a@ex.com'),
        ]),
        imapConnect: (account, username, password) async => client,
        appLogger: logger,
      );

  Future<void> seedNotesCheckpoint(Map<String, Object> state) =>
      db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: _accountId,
              resourceType: 'notes',
              state: jsonEncode(state),
              syncedAt: DateTime(2026),
            ),
          );

  /// Syncs three times, then returns the `note.sync.completed` rows (any
  /// level). The repo logs fire-and-forget, so a sentinel is logged after the
  /// syncs and awaited until it is in the table — earlier writes are queued
  /// before it, so an empty result can't be a not-yet-flushed one.
  Future<List<AppLogRow>> syncThriceAndReadLogs(NoteRepositoryImpl repo) async {
    for (var i = 0; i < 3; i++) {
      await repo.syncAllNotes(_accountId);
    }
    unawaited(logger.info(_sentinelEvent, 'flush'));
    final rows = db.select(db.appLogs);
    for (var i = 0;; i++) {
      if ((await rows.get()).any((r) => r.event == _sentinelEvent)) break;
      if (i > 100) fail('sentinel log row never landed');
      await Future<void>.delayed(Duration.zero);
    }
    return (db.select(db.appLogs)
          ..where((t) => t.event.equals('note.sync.completed')))
        .get();
  }

  final missingFolder = SelectingFakeImapClient(
    selectError: Exception('NO [TRYCREATE] Mailbox does not exist'),
  );

  test('IMAP: repeated syncs without Notes folder log nothing', () async {
    expect(await syncThriceAndReadLogs(imapRepo(missingFolder)), isEmpty);
  });

  test('IMAP: a sync that wipes cached notes logs exactly once', () async {
    await seedNotesCheckpoint({'uidValidity': 1, 'lastUid': 5});
    await db.into(db.emailNotes).insert(
          EmailNotesCompanion.insert(
            id: 'n-stale',
            accountId: _accountId,
            messageId: '<a@ex.com>',
            noteText: 'stale',
            serverId: '5',
            createdAt: DateTime(2026),
          ),
        );

    final logs = await syncThriceAndReadLogs(imapRepo(missingFolder));

    expect(logs, hasLength(1));
    expect(
      jsonDecode(logs.single.dataJson!),
      {'transport': 'imap', 'wiped': 1, 'checkpointCleared': true},
    );
    expect(await db.select(db.emailNotes).get(), isEmpty);
  });

  test('IMAP: incremental syncs with no changes log nothing', () async {
    // uidValidity 0 matches the fake mailbox → incremental path; the fake
    // returns no UIDs, so nothing is fetched or pruned.
    await seedNotesCheckpoint({'uidValidity': 0, 'lastUid': 5});

    expect(
      await syncThriceAndReadLogs(imapRepo(SnoozeSpyImapClient())),
      isEmpty,
    );
  });

  test('JMAP: repeated syncs without Notes mailbox log nothing', () async {
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return jmapSessionResponse(accountId: 'u1');
      }
      return http.Response(
        jsonEncode({
          'sessionState': 'sess1',
          'methodResponses': [
            [
              'Mailbox/get',
              {'accountId': 'u1', 'list': <Object>[], 'state': 'mb-1'},
              '0',
            ],
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = NoteRepositoryImpl(
      db,
      FakeAccountRepository([
        const Account(
          id: _accountId,
          displayName: 'a',
          email: 'a@ex.com',
          type: AccountType.jmap,
          jmapUrl: 'https://jmap.example.com/.well-known/jmap',
        ),
      ]),
      httpClient: client,
      appLogger: logger,
    );

    expect(await syncThriceAndReadLogs(repo), isEmpty);
  });
}
