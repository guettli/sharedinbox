import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

import 'db_test_helper.dart';
import 'fake_imap.dart';
import 'helpers/fake_account_repository.dart';

const _accountId = 'imap-no-notes';

/// A server without a Notes folder (the default on most IMAP servers) must
/// not flood the App Log at info level on every sync cycle — only a sync
/// that actually clears cached state is worth an info entry.
void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late NoteRepositoryImpl repo;

  setUp(() async {
    db = await openTestDatabaseWithAccounts([_accountId]);
    repo = NoteRepositoryImpl(
      db,
      FakeAccountRepository([
        const Account(
          id: _accountId,
          displayName: _accountId,
          email: '$_accountId@example.com',
        ),
      ]),
      imapConnect: (account, username, password) async =>
          SelectingFakeImapClient(
        selectError: Exception('NO [TRYCREATE] Mailbox does not exist'),
      ),
      appLogger: AppLogger(AppLogRepositoryImpl(db)),
    );
  });
  tearDown(() => db.close());

  /// Syncs three times and returns the info-level `note.sync.completed`
  /// rows written to the App Log.
  Future<List<AppLogRow>> syncThriceAndReadInfoLogs() async {
    for (var i = 0; i < 3; i++) {
      await repo.syncAllNotes(_accountId);
    }
    // Log writes are fire-and-forget; let them land.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return (db.select(db.appLogs)
          ..where(
            (t) =>
                t.event.equals('note.sync.completed') &
                t.level.equals(AppLogLevel.info.wireName),
          ))
        .get();
  }

  test('repeated syncs with nothing to clear log nothing at info', () async {
    expect(await syncThriceAndReadInfoLogs(), isEmpty);
  });

  test('a sync that wipes cached notes logs exactly once at info', () async {
    await db.into(db.syncStates).insert(
          SyncStatesCompanion.insert(
            accountId: _accountId,
            resourceType: 'notes',
            state: jsonEncode({'uidValidity': 1, 'lastUid': 5}),
            syncedAt: DateTime(2026),
          ),
        );
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

    final infos = await syncThriceAndReadInfoLogs();

    expect(infos, hasLength(1));
    expect(
      jsonDecode(infos.single.dataJson!),
      {'transport': 'imap', 'wiped': 1, 'checkpointCleared': true},
    );
    expect(await db.select(db.emailNotes).get(), isEmpty);
  });
}
