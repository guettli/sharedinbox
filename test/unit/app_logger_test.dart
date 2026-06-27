import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';

class _RecordingRepo implements AppLogRepository {
  final inserts = <Map<String, Object?>>[];

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    inserts.add({
      'level': level,
      'event': event,
      'message': message,
      'dataJson': dataJson,
      'screen': screen,
      'accountId': accountId,
      'mailboxPath': mailboxPath,
      'emailId': emailId,
      'syncLogId': syncLogId,
    });
    return inserts.length;
  }

  @override
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter) =>
      Stream.value(const []);

  @override
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  }) async {}

  @override
  Future<void> clearAll() async {}
}

void main() {
  test('debug/info/warn/error wrappers set the level', () async {
    final repo = _RecordingRepo();
    final logger = AppLogger(repo);

    await logger.debug('e', 'd');
    await logger.info('e', 'i');
    await logger.warn('e', 'w');
    await logger.error('e', 'r');

    expect(
      repo.inserts.map((m) => m['level']).toList(),
      [
        AppLogLevel.debug,
        AppLogLevel.info,
        AppLogLevel.warn,
        AppLogLevel.error,
      ],
    );
  });

  test('encodeData merges data, error and stack into a JSON object', () {
    final encoded = AppLogger.encodeData(
      {'k': 'v', 'n': 3},
      error: Exception('boom'),
      stack: StackTrace.fromString('frame'),
    )!;
    final decoded = jsonDecode(encoded) as Map<String, Object?>;
    expect(decoded['k'], 'v');
    expect(decoded['n'], 3);
    expect(decoded['error'], contains('boom'));
    expect(decoded['stack'], contains('frame'));
  });

  test('encodeData returns null when nothing extra is supplied', () {
    expect(AppLogger.encodeData(null), isNull);
    expect(AppLogger.encodeData(const {}), isNull);
  });

  test('encodeData falls back to toString for non-encodable values', () {
    final encoded = AppLogger.encodeData({'x': _NotJson()})!;
    final decoded = jsonDecode(encoded) as Map<String, Object?>;
    expect(decoded['x'], 'not-json');
  });

  test('context fields and dataJson are forwarded to the repository', () async {
    final repo = _RecordingRepo();
    final logger = AppLogger(repo);

    await logger.warn(
      'sync.retry',
      'Retrying',
      data: {'attempt': 2},
      accountId: 'acc1',
      mailboxPath: 'INBOX',
      emailId: 'acc1:INBOX:5',
      syncLogId: 7,
    );

    expect(repo.inserts, hasLength(1));
    final row = repo.inserts.single;
    expect(row['event'], 'sync.retry');
    expect(row['message'], 'Retrying');
    expect(row['accountId'], 'acc1');
    expect(row['mailboxPath'], 'INBOX');
    expect(row['emailId'], 'acc1:INBOX:5');
    expect(row['syncLogId'], 7);
    final dataJson = row['dataJson'] as String?;
    expect(dataJson, isNotNull);
    expect(jsonDecode(dataJson!), {'attempt': 2});
  });

  test('insert failure in the repo does not throw out of log()', () async {
    final logger = AppLogger(_ThrowingRepo());
    await expectLater(
      logger.info('e', 'm'),
      completes,
    );
  });
}

class _NotJson {
  @override
  String toString() => 'not-json';
}

class _ThrowingRepo implements AppLogRepository {
  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    throw StateError('db gone');
  }

  @override
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter) =>
      Stream.value(const []);

  @override
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  }) async {}

  @override
  Future<void> clearAll() async {}
}
