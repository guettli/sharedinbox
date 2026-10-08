import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;

  setUp(() => db = openTestDatabase());
  tearDown(() => db.close());

  test('recordBugReport stores all fields and loadBugReports reads them back',
      () async {
    final createdAt = DateTime(2026, 3, 5, 9, 30);
    await db.recordBugReport(
      issueUrl: 'https://github.com/guettli/sharedinbox/issues/900',
      issueNumber: 900,
      reportId: 'uuid-123',
      createdAt: createdAt,
    );

    final rows = await db.loadBugReports();
    expect(rows, hasLength(1));
    expect(
      rows.single.issueUrl,
      'https://github.com/guettli/sharedinbox/issues/900',
    );
    expect(rows.single.issueNumber, 900);
    expect(rows.single.reportId, 'uuid-123');
    expect(rows.single.createdAt, createdAt);
  });

  test('recordBugReport allows null issueNumber and reportId', () async {
    await db.recordBugReport(
      issueUrl: 'https://example.com/issue',
      createdAt: DateTime(2026, 2, 3),
    );

    final rows = await db.loadBugReports();
    expect(rows.single.issueNumber, isNull);
    expect(rows.single.reportId, isNull);
  });

  test('loadBugReports returns rows newest first', () async {
    await db.recordBugReport(
      issueUrl: 'https://example.com/1',
      issueNumber: 1,
      createdAt: DateTime(2026, 1, 5),
    );
    await db.recordBugReport(
      issueUrl: 'https://example.com/3',
      issueNumber: 3,
      createdAt: DateTime(2026, 3, 5),
    );
    await db.recordBugReport(
      issueUrl: 'https://example.com/2',
      issueNumber: 2,
      createdAt: DateTime(2026, 2, 5),
    );

    final rows = await db.loadBugReports();
    expect(rows.map((r) => r.issueNumber).toList(), [3, 2, 1]);
  });

  test('loadBugReports returns an empty list when nothing is recorded',
      () async {
    expect(await db.loadBugReports(), isEmpty);
  });
}
