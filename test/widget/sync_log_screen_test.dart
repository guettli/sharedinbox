import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/sync_log_screen.dart';

/// A sync-log repository whose [observeSyncLogs] stream the test drives by
/// hand, so we can inspect what the screen renders before the first emission
/// arrives (issue #632: the empty state must not flash while loading).
class _ControllableSyncLog extends NoOpSyncLogRepository {
  final _controller = StreamController<List<SyncLogEntry>>();

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      _controller.stream;

  void emit(List<SyncLogEntry> entries) => _controller.add(entries);

  void dispose() => _controller.close();
}

SyncLogEntry _entry({int id = 1}) => SyncLogEntry(
      id: id,
      result: 'ok',
      protocol: 'imap',
      emailsFetched: 3,
      emailsSkipped: 0,
      mailboxesSynced: 1,
      pendingFlushed: 0,
      bytesTransferred: 1024,
      startedAt: DateTime(2026, 8, 18, 14, 16, 45),
      finishedAt: DateTime(2026, 8, 18, 14, 17, 6),
    );

void main() {
  late _ControllableSyncLog repo;

  setUp(() => repo = _ControllableSyncLog());
  tearDown(() => repo.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncLogRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: SyncLogScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows a spinner (not the empty state) before the first emission',
      (tester) async {
    await pump(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No sync entries yet'), findsNothing);
  });

  testWidgets('shows the empty state once an empty list is emitted',
      (tester) async {
    await pump(tester);

    repo.emit([]);
    await tester.pump();

    expect(find.text('No sync entries yet'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('renders entries once they arrive', (tester) async {
    await pump(tester);

    repo.emit([_entry(), _entry(id: 2)]);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No sync entries yet'), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });
}
