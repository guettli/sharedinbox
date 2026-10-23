import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/crash_logger.dart';
import 'package:sharedinbox/core/services/notification_guard.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  // #1107: a notification backend that fails or never answers must not
  // escape to the caller.
  group('guardNotificationShow', () {
    late List<String> warnings;

    setUp(() => warnings = []);

    Future<bool> guard(
      Future<void> Function() show, {
      Duration timeout = const Duration(milliseconds: 50),
    }) =>
        guardNotificationShow(
          show,
          timeout: timeout,
          onFailure: (message, _, __) => warnings.add(message),
        );

    test('returns true and warns nothing when the show succeeds', () async {
      expect(await guard(() async {}), isTrue);
      expect(warnings, isEmpty);
    });

    test('swallows an async exception', () async {
      final shown = await guard(() async => throw StateError('no daemon'));
      expect(shown, isFalse);
      expect(warnings.single, contains('no daemon'));
    });

    test('swallows a synchronous throw from the show callback', () async {
      final shown = await guard(() => throw StateError('sync'));
      expect(shown, isFalse);
      expect(warnings.single, contains('sync'));
    });

    test('gives up on a show that never completes', () async {
      final shown = await guard(() => Completer<void>().future);
      expect(shown, isFalse);
      expect(warnings.single, contains('no reply within 50 ms'));
    });
  });
  group('default failure log', () {
    configureSqliteForTests();

    late AppDatabase db;

    setUp(() async {
      db = openTestDatabase();
      // The ids name no seeded rows; without FKs the log keeps them as given.
      await db.customStatement('PRAGMA foreign_keys = OFF');
      crashLogger = AppLogger(AppLogRepositoryImpl(db));
    });

    tearDown(() async {
      crashLogger = null;
      await db.close();
    });

    test('records which account and mail failed to notify', () async {
      final shown = await guardNotificationShow(
        () async => throw StateError('ServiceUnknown'),
        accountId: 'acc-1',
        emailId: 'acc-1:INBOX:42',
      );
      expect(shown, isFalse);

      // logUncaught inserts fire-and-forget; poll until the row lands.
      var rows = <AppLogRow>[];
      for (var i = 0; i < 200 && rows.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        rows = await db.select(db.appLogs).get();
      }
      final row = rows.single;
      expect(row.event, 'notification.show_failed');
      expect(row.level, 'warn');
      expect(row.accountId, 'acc-1');
      expect(row.emailId, 'acc-1:INBOX:42');
    });
  });
}
