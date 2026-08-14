import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/crash_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;

  setUp(() {
    db = openTestDatabase();
    crashLogger = AppLogger(AppLogRepositoryImpl(db));
  });

  tearDown(() async {
    crashLogger = null;
    // The "log store unavailable" test closes the db itself; closing twice is
    // harmless but can throw, so swallow it here.
    try {
      await db.close();
    } catch (_) {}
  });

  // logUncaught fires the insert without awaiting it, so poll until it lands.
  Future<void> waitForRow() async {
    for (var i = 0; i < 200; i++) {
      if ((await db.select(db.appLogs).get()).isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('logUncaught is a no-op when no crashLogger is attached', () {
    crashLogger = null;
    // Must not throw even with nothing wired up (e.g. an early-startup crash
    // before ProviderScope exists).
    expect(
      () => logUncaught('app.flutter_error', 'boom', Exception('boom'), null),
      returnsNormally,
    );
  });

  test('logUncaught records an error row via the attached logger', () async {
    logUncaught(
      'app.flutter_error',
      'Something broke',
      Exception('boom'),
      StackTrace.fromString('frame'),
      screen: 'HomeScreen',
    );

    await waitForRow();
    final rows = await db.select(db.appLogs).get();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.level, 'error');
    expect(row.event, 'app.flutter_error');
    expect(row.message, 'Something broke');
    expect(row.screen, 'HomeScreen');
    expect(row.dataJson, contains('boom'));
    expect(row.dataJson, contains('frame'));
  });

  test('logUncaught honours the requested level (transient → warn)', () async {
    logUncaught(
      'app.flutter_error',
      'offline',
      Exception('SocketException'),
      null,
      level: AppLogLevel.warn,
    );

    await waitForRow();
    final rows = await db.select(db.appLogs).get();
    expect(rows.single.level, 'warn');
  });

  test('logUncaught never throws even when the log store is unavailable',
      () async {
    await db.close(); // subsequent inserts fail inside the repository
    expect(
      () => logUncaught('app.zone_error', 'boom', Exception('boom'), null),
      returnsNormally,
    );
    await Future<void>.delayed(Duration.zero);
  });
}
