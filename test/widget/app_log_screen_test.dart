import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/app_log_screen.dart';

class _MemRepo implements AppLogRepository {
  _MemRepo(this._rows);
  final List<AppLogEntry> _rows;

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
    final id = _rows.length + 1;
    _rows.add(
      AppLogEntry(
        id: id,
        createdAt: createdAt ?? DateTime.now(),
        level: level,
        event: event,
        message: message,
        dataJson: dataJson,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
      ),
    );
    return id;
  }

  @override
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter) {
    final filtered = _rows.where((r) {
      if (!filter.levels.contains(r.level)) return false;
      if (filter.accountId != null && r.accountId != filter.accountId) {
        return false;
      }
      if (filter.syncLogId != null && r.syncLogId != filter.syncLogId) {
        return false;
      }
      final s = filter.search?.trim();
      if (s != null && s.isNotEmpty) {
        final needle = s.toLowerCase();
        if (!r.event.toLowerCase().contains(needle) &&
            !r.message.toLowerCase().contains(needle)) {
          return false;
        }
      }
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Stream.value(filtered.take(filter.limit).toList());
  }

  @override
  Stream<AppLogEntry?> watchLatestForAccount({
    required String accountId,
    required String event,
  }) {
    final matches = _rows.where(
      (r) => r.accountId == accountId && r.event == event,
    );
    if (matches.isEmpty) return Stream.value(null);
    final sorted = matches.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Stream.value(sorted.first);
  }

  @override
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  }) async {}

  @override
  Future<void> clearAll() async => _rows.clear();
}

void main() {
  testWidgets('AppLogScreen hides debug entries by default', (tester) async {
    final repo = _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.debug,
        event: 'ui.screen.enter',
        message: '/inbox',
      ),
      AppLogEntry(
        id: 2,
        createdAt: DateTime(2024, 1, 1, 11),
        level: AppLogLevel.info,
        event: 'sync.cycle.complete',
        message: 'ok',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLogRepositoryProvider.overrideWithValue(repo),
          allAccountsProvider.overrideWith((ref) => Stream.value(<Account>[])),
        ],
        child: const MaterialApp(home: AppLogScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('sync.cycle.complete'), findsOneWidget);
    expect(find.textContaining('ui.screen.enter'), findsNothing);
  });

  testWidgets('toggling debug chip reveals debug entries', (tester) async {
    final repo = _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.debug,
        event: 'ui.screen.enter',
        message: '/inbox',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLogRepositoryProvider.overrideWithValue(repo),
          allAccountsProvider.overrideWith((ref) => Stream.value(<Account>[])),
        ],
        child: const MaterialApp(home: AppLogScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('ui.screen.enter'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'debug'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ui.screen.enter'), findsOneWidget);
  });

  testWidgets('AppLogScreen pre-filters by syncLogId when supplied',
      (tester) async {
    final repo = _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.info,
        event: 'other',
        message: '',
        syncLogId: 7,
      ),
      AppLogEntry(
        id: 2,
        createdAt: DateTime(2024, 1, 1, 11),
        level: AppLogLevel.info,
        event: 'unrelated',
        message: '',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLogRepositoryProvider.overrideWithValue(repo),
          allAccountsProvider.overrideWith((ref) => Stream.value(<Account>[])),
        ],
        child: const MaterialApp(home: AppLogScreen(initialSyncLogId: 7)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('sync #7'), findsOneWidget);
    expect(find.textContaining('other'), findsOneWidget);
    expect(find.textContaining('unrelated'), findsNothing);
  });
}
