import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/app_log_screen.dart';

import 'helpers.dart';

class _MemRepo extends NoOpAppLogRepository {
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
      if (filter.emailId != null && r.emailId != filter.emailId) {
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
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Stream.value(filtered.take(filter.limit).toList());
  }

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

  testWidgets('AppLogScreen pre-filters by syncLogId when supplied', (
    tester,
  ) async {
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

  testWidgets('AppLogScreen pre-filters by emailId when supplied', (
    tester,
  ) async {
    final repo = _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.info,
        event: 'for-this-message',
        message: '',
        emailId: 'acc-1:42',
      ),
      AppLogEntry(
        id: 2,
        createdAt: DateTime(2024, 1, 1, 11),
        level: AppLogLevel.info,
        event: 'for-another-message',
        message: '',
        emailId: 'acc-1:99',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLogRepositoryProvider.overrideWithValue(repo),
          allAccountsProvider.overrideWith((ref) => Stream.value(<Account>[])),
        ],
        child: const MaterialApp(
          home: AppLogScreen(initialEmailId: 'acc-1:42'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('email=acc-1:42'), findsOneWidget);
    expect(find.textContaining('for-this-message'), findsOneWidget);
    expect(find.textContaining('for-another-message'), findsNothing);
  });

  group('mailbox display path', () {
    // A sync.folder entry whose mailboxPath is an opaque JMAP server id ("a").
    _MemRepo syncFolderRepo() => _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.info,
        event: 'sync.folder',
        message: 'synced',
        accountId: 'acc-1',
        mailboxPath: 'a',
      ),
    ]);

    // Pump the AppLogScreen with the given mailbox cache and open the entry.
    Future<void> pumpAndOpen(
      WidgetTester tester,
      FakeMailboxRepository mailboxRepo,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLogRepositoryProvider.overrideWithValue(syncFolderRepo()),
            allAccountsProvider.overrideWith(
              (ref) => Stream.value(<Account>[]),
            ),
            mailboxRepositoryProvider.overrideWithValue(mailboxRepo),
          ],
          child: const MaterialApp(home: AppLogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('sync.folder'));
      await tester.pumpAndSettle();
    }

    testWidgets('resolves an opaque mailbox id to its display path', (
      tester,
    ) async {
      await pumpAndOpen(
        tester,
        FakeMailboxRepository([
          const Mailbox(
            id: 'acc-1:a',
            accountId: 'acc-1',
            path: 'a',
            name: '2026',
            displayPath: 'Archive/2026',
            unreadCount: 0,
            totalCount: 0,
          ),
        ]),
      );

      expect(find.widgetWithText(Chip, 'mailbox=Archive/2026'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'mailbox=a'), findsNothing);
    });

    testWidgets('falls back to the raw mailbox path when not cached', (
      tester,
    ) async {
      // No mailbox with path "a" is cached → resolver returns the raw path.
      await pumpAndOpen(tester, FakeMailboxRepository());

      expect(find.widgetWithText(Chip, 'mailbox=a'), findsOneWidget);
    });
  });

  testWidgets('renders a dedicated stack trace section', (tester) async {
    final repo = _MemRepo([
      AppLogEntry(
        id: 1,
        createdAt: DateTime(2024, 1, 1, 10),
        level: AppLogLevel.error,
        event: 'sync.cycle.failed',
        message: 'boom',
        dataJson: jsonEncode({
          'protocol': 'imap',
          'stack': '#0 doThing\n#1 main',
        }),
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

    await tester.tap(find.textContaining('sync.cycle.failed'));
    await tester.pumpAndSettle();

    // The stack trace gets its own section, separate from the JSON "Data" blob.
    expect(find.text('Stack trace'), findsOneWidget);
    expect(find.textContaining('#0 doThing'), findsOneWidget);
    // The remaining structured fields still render, without the stack in them.
    expect(find.textContaining('"protocol": "imap"'), findsOneWidget);
    expect(find.textContaining('"stack"'), findsNothing);
  });

  group('email hyperlink', () {
    Widget host({
      required AppLogRepository logRepo,
      required FakeEmailRepository emailRepo,
      ValueNotifier<String?>? lastEmailRoute,
    }) {
      final router = GoRouter(
        initialLocation: '/app-log',
        routes: [
          GoRoute(
            path: '/app-log',
            builder: (ctx, state) => const AppLogScreen(),
          ),
          GoRoute(
            path: '/accounts/:accountId/mailboxes/:mailboxPath/emails/:emailId',
            builder: (ctx, state) {
              lastEmailRoute?.value = state.uri.toString();
              return const Scaffold(body: Text('email-detail-route'));
            },
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          appLogRepositoryProvider.overrideWithValue(logRepo),
          emailRepositoryProvider.overrideWithValue(emailRepo),
          allAccountsProvider.overrideWith((ref) => Stream.value(<Account>[])),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    AppLogEntry entryForEmail(String emailId) => AppLogEntry(
      id: 1,
      createdAt: DateTime(2024, 1, 1, 10),
      level: AppLogLevel.info,
      event: 'email.trust_image_sender',
      message: 'Images will be loaded automatically for this sender.',
      emailId: emailId,
    );

    testWidgets('renders a tappable link that opens the message', (
      tester,
    ) async {
      final email = testEmail();
      final lastRoute = ValueNotifier<String?>(null);
      await tester.pumpWidget(
        host(
          logRepo: _MemRepo([entryForEmail(email.id)]),
          emailRepo: FakeEmailRepository(emailDetail: email),
          lastEmailRoute: lastRoute,
        ),
      );
      await tester.pumpAndSettle();

      // Badges live in the collapsed ExpansionTile — expand it first.
      await tester.tap(find.textContaining('email.trust_image_sender'));
      await tester.pumpAndSettle();

      // The email badge is present as an action chip.
      final link = find.widgetWithText(ActionChip, 'email=acc-1:42');
      expect(link, findsOneWidget);

      await tester.tap(link);
      await tester.pumpAndSettle();

      expect(find.text('email-detail-route'), findsOneWidget);
      expect(
        lastRoute.value,
        '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
      );
    });

    testWidgets('shows a fallback when the message no longer exists', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          logRepo: _MemRepo([entryForEmail('acc-1:999')]),
          // getEmail falls back to _emailDetail (null here) → not found.
          emailRepo: FakeEmailRepository(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('email.trust_image_sender'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ActionChip, 'email=acc-1:999'));
      await tester.pumpAndSettle();

      expect(find.text('Message no longer available'), findsOneWidget);
      expect(find.text('email-detail-route'), findsNothing);
    });
  });
}
