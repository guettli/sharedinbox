import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mockito/annotations.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'db_test_helper.dart';
import 'email_repository_cancel_change_test.mocks.dart';

@GenerateMocks([http.Client, SecureStorage])
void main() {
  late AppDatabase db;
  late EmailRepositoryImpl repo;
  late MockClient mockHttpClient;
  late MockSecureStorage mockStorage;

  setUpAll(() {
    configureSqliteForTests();
  });

  setUp(() async {
    db = openTestDatabase();
    mockHttpClient = MockClient();
    mockStorage = MockSecureStorage();
    final accounts = AccountRepositoryImpl(db, mockStorage);
    repo = EmailRepositoryImpl(
      db,
      accounts,
      httpClient: mockHttpClient,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('cancelPendingChange removes an unattempted change', () async {
    await db.into(db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: 'acc1',
            resourceType: 'Email',
            resourceId: 'e1',
            changeType: 'move',
            payload: '{}',
            createdAt: DateTime.now(),
          ),
        );

    final cancelled = await repo.cancelPendingChange('e1', 'move');
    expect(cancelled, isTrue);

    final remaining = await db.select(db.pendingChanges).get();
    expect(remaining, isEmpty);
  });

  test('cancelPendingChange does not remove attempted changes', () async {
    await db.into(db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: 'acc1',
            resourceType: 'Email',
            resourceId: 'e1',
            changeType: 'move',
            payload: '{}',
            createdAt: DateTime.now(),
            attempts: const Value(1),
          ),
        );

    final cancelled = await repo.cancelPendingChange('e1', 'move');
    expect(cancelled, isFalse);

    final remaining = await db.select(db.pendingChanges).get();
    expect(remaining, hasLength(1));
  });

  test('cancelPendingChange only removes the latest matching change', () async {
    final now = DateTime.now();
    await db.into(db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: 'acc1',
            resourceType: 'Email',
            resourceId: 'e1',
            changeType: 'move',
            payload: '{"id": 1}',
            createdAt: now,
          ),
        );
    await db.into(db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: 'acc1',
            resourceType: 'Email',
            resourceId: 'e1',
            changeType: 'move',
            payload: '{"id": 2}',
            createdAt: now.add(const Duration(seconds: 1)),
          ),
        );

    final cancelled = await repo.cancelPendingChange('e1', 'move');
    expect(cancelled, isTrue);

    final remaining = await db.select(db.pendingChanges).get();
    expect(remaining, hasLength(1));
    expect(remaining.first.payload, '{"id": 1}');
  });
}
