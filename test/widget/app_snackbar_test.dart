import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// Records every insert so tests can assert what the snackbar logged.
class _RecordingRepo extends NoOpAppLogRepository {
  final List<AppLogEntry> rows = [];

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
    final id = rows.length + 1;
    rows.add(
      AppLogEntry(
        id: id,
        createdAt: createdAt ?? DateTime(2024, 6),
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
}

Widget _host(_RecordingRepo repo, void Function(BuildContext) onTap) {
  return ProviderScope(
    overrides: [appLogRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onTap(context),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('showAppSnackBar shows the snack and logs it', (tester) async {
    final repo = _RecordingRepo();
    await tester.pumpWidget(
      _host(
        repo,
        (context) => context.showAppSnackBar(
          'Something happened',
          level: AppLogLevel.warn,
          event: 'test.event',
          emailId: 'acc-1:42',
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // The message is on screen…
    expect(find.text('Something happened'), findsOneWidget);
    // …and recorded in the App Log with the level/email/event we passed.
    expect(repo.rows, hasLength(1));
    final entry = repo.rows.single;
    expect(entry.message, 'Something happened');
    expect(entry.level, AppLogLevel.warn);
    expect(entry.event, 'test.event');
    expect(entry.emailId, 'acc-1:42');
  });

  testWidgets('appMessenger() captured before an await still logs', (
    tester,
  ) async {
    final repo = _RecordingRepo();
    await tester.pumpWidget(
      _host(repo, (context) {
        final messenger = context.appMessenger();
        messenger.show('Done', event: 'test.deferred');
      }),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Done'), findsOneWidget);
    expect(repo.rows.single.event, 'test.deferred');
    // Level defaults to info.
    expect(repo.rows.single.level, AppLogLevel.info);
  });

  testWidgets('still shows the snack when no ProviderScope is present', (
    tester,
  ) async {
    // The crash boundary renders before runApp, so there is no ProviderScope
    // above the context. Logging is skipped, but the snack must still appear
    // and no exception may escape.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => context.showAppSnackBar('No scope here'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('No scope here'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
