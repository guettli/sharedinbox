import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/services/body_cache_service.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';

class _FakeAccountRepo extends Fake implements AccountRepository {}

/// Writes a small body row for each fetched message, except for [failing]
/// ids (or every id while [offline]).
class _FakeFetcher implements BodyFetcher {
  _FakeFetcher(this.db, {this.failing = const {}, this.offline = false});

  final AppDatabase db;
  final Set<String> failing;
  final bool offline;
  final fetched = <String>[];
  var closed = 0;

  @override
  Future<void> fetch(String emailId) async {
    fetched.add(emailId);
    if (offline || failing.contains(emailId)) throw StateError('fail');
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: const Value('body'),
            cachedAt: Value(DateTime.utc(2026)),
          ),
        );
  }

  @override
  Future<void> close() async => closed++;
}

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;

  setUp(() async {
    db = await openTestDatabaseWithAccounts(['a']);
    await seedInboxMailbox(db, 'a');
  });

  tearDown(() => db.close());

  Future<void> seedEmails(int n) async {
    for (var i = 1; i <= n; i++) {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'a:INBOX:$i',
              accountId: 'a',
              mailboxPath: 'INBOX',
              uid: i,
              receivedAt: DateTime.utc(2026).add(Duration(minutes: i)),
            ),
          );
    }
  }

  Future<int> bodyCount() async =>
      (await db.select(db.emailBodies).get()).length;

  BodyCacheService service(_FakeFetcher fetcher, {DateTime? now}) =>
      BodyCacheService(
        db,
        _FakeAccountRepo(),
        fetcherFactory: () => fetcher,
        clock: () => now ?? DateTime.utc(2026, 6),
      );

  test('one batch of 20 by default (WorkManager behaviour)', () async {
    await seedEmails(50);
    final fetcher = _FakeFetcher(db);
    expect(await service(fetcher).run(), 20);
    expect(await bodyCount(), 20);
    expect(fetcher.closed, 1);
  });

  test('loops batches until nothing is left', () async {
    await seedEmails(50);
    final fetcher = _FakeFetcher(db);
    expect(await service(fetcher).run(maxBatches: 10), 50);
    expect(await bodyCount(), 50);
    expect(fetcher.fetched, hasLength(50));
    expect(fetcher.closed, 1);
  });

  test('respects maxBatches', () async {
    await seedEmails(100);
    expect(await service(_FakeFetcher(db)).run(maxBatches: 3), 60);
  });

  test('stops after a batch without progress (offline)', () async {
    await seedEmails(50);
    final fetcher = _FakeFetcher(db, offline: true);
    final s = service(fetcher);
    expect(await s.run(maxBatches: 10), 0);
    expect(fetcher.fetched, hasLength(20));
    // Not marked as failed: the next run retries the same, newest messages.
    final retry = _FakeFetcher(db);
    final s2 = BodyCacheService(
      db,
      _FakeAccountRepo(),
      fetcherFactory: () => retry,
    );
    await s2.run();
    expect(retry.fetched.first, 'a:INBOX:50');
  });

  test('stops when the cache limit is reached', () async {
    await seedEmails(50);
    await db.into(db.userPreferences).insertOnConflictUpdate(
          const UserPreferencesCompanion(
            id: Value(1),
            bodyCacheLimitMb: Value(0),
          ),
        );
    expect(await service(_FakeFetcher(db)).run(maxBatches: 10), 0);
    expect(await bodyCount(), 0);
  });

  test('skips recently failed messages on later runs, retries after 24h',
      () async {
    await seedEmails(30);
    var now = DateTime.utc(2026, 6);
    final failing = {'a:INBOX:30', 'a:INBOX:29'};
    final fetcher = _FakeFetcher(db, failing: failing);
    final s = BodyCacheService(
      db,
      _FakeAccountRepo(),
      fetcherFactory: () => fetcher,
      clock: () => now,
    );
    expect(await s.run(), 18);

    fetcher.fetched.clear();
    expect(await s.run(), 10);
    expect(fetcher.fetched, isNot(contains('a:INBOX:30')));

    now = now.add(BodyCacheService.failedRetryAfter);
    fetcher.fetched.clear();
    await s.run();
    expect(fetcher.fetched, containsAll(failing));
  });
}
