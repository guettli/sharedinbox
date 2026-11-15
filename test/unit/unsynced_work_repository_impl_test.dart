import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/unsynced_work_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;
  late UnsyncedWorkRepositoryImpl repo;

  setUp(() async {
    db = openTestDatabase();
    repo = UnsyncedWorkRepositoryImpl(db);
    await seedAccountRow(db, 'acc1');
    await seedAccountRow(db, 'acc2');
  });

  tearDown(() => db.close());

  Future<void> change(String accountId) => db.into(db.pendingChanges).insert(
        PendingChangesCompanion.insert(
          accountId: accountId,
          resourceType: 'email',
          resourceId: '$accountId:INBOX:1',
          changeType: 'flag_seen',
          payload: '{"seen":true}',
          createdAt: DateTime(2026),
        ),
      );

  Future<void> outbox(String accountId, {String status = 'pending'}) =>
      db.into(db.outbox).insert(
            OutboxCompanion.insert(
              accountId: accountId,
              mimeBase64: '',
              envelopeJson: '{}',
              createdAt: DateTime(2026),
              status: Value(status),
            ),
          );

  Future<void> note(
    String id,
    String accountId, {
    bool pendingUpload = false,
    bool pendingDelete = false,
  }) =>
      db.into(db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: id,
              accountId: accountId,
              messageId: '<$id@ex.com>',
              noteText: id,
              serverId: '',
              createdAt: DateTime(2026),
              pendingUpload: Value(pendingUpload),
              pendingDelete: Value(pendingDelete),
            ),
          );

  test('an account with nothing queued has no unsynced work', () async {
    await note('synced', 'acc1');

    final work = await repo.countForAccount('acc1');

    expect(work.isEmpty, isTrue);
    expect(work.describe(), isEmpty);
  });

  Future<void> localFilter(String accountId) =>
      db.into(db.localSieveScripts).insert(
            LocalSieveScriptsCompanion.insert(
              accountId: accountId,
              name: 'f',
            ),
          );

  Future<void> notificationRule(String accountId) =>
      db.into(db.notificationRules).insert(
            NotificationRulesCompanion.insert(
              accountId: accountId,
              expressionJson: '{}',
              createdAt: DateTime(2026),
            ),
          );

  test('counts everything that exists only on this device', () async {
    await change('acc1');
    await change('acc1');
    await outbox('acc1');
    await outbox('acc1', status: 'failed');
    await note('added', 'acc1', pendingUpload: true);
    // Deleted locally: the server still has it, nothing is lost.
    await note('deleted', 'acc1', pendingDelete: true);
    // Added and deleted again before upload: nothing to lose either.
    await note('both', 'acc1', pendingUpload: true, pendingDelete: true);
    await note('synced', 'acc1');
    await localFilter('acc1');
    await notificationRule('acc1');
    await notificationRule('acc1');
    // Another account's work does not count.
    await change('acc2');
    await outbox('acc2');
    await note('other', 'acc2', pendingUpload: true);
    await localFilter('acc2');
    await notificationRule('acc2');

    final work = await repo.countForAccount('acc1');

    expect(work.queuedChanges, 2);
    expect(work.unsentEmails, 2);
    expect(work.unsyncedNotes, 1);
    expect(work.localFilters, 1);
    expect(work.notificationRules, 2);
    expect(work.isEmpty, isFalse);
  });
}
