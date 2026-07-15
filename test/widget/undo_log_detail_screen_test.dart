import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/undo_log_detail_screen.dart';

import 'helpers.dart';

// FakeEmailRepository subclass that returns a pre-configured email from
// findEmailByMessageId, so the tap handler in UndoLogDetailScreen can be
// exercised without a real database.
class _LookupEmailRepository extends FakeEmailRepository {
  _LookupEmailRepository(this._lookup);

  final Email? _lookup;

  @override
  Future<Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async =>
      _lookup;
}

UndoAction _action({
  required List<Email> originalEmails,
  List<String>? emailIds,
  String accountId = 'acc-1',
  String sourceMailboxPath = 'INBOX',
  String? destinationMailboxPath = 'Archive',
}) =>
    UndoAction(
      id: 'undo-1',
      accountId: accountId,
      type: UndoType.move,
      emailIds: emailIds ?? originalEmails.map((e) => e.id).toList(),
      sourceMailboxPath: sourceMailboxPath,
      destinationMailboxPath: destinationMailboxPath,
      originalEmails: originalEmails,
      timestamp: DateTime(2024, 6),
    );

Mailbox _mailbox({
  required String path,
  required String name,
  String? displayPath,
  String accountId = 'acc-1',
}) =>
    Mailbox(
      id: '$accountId:$path',
      accountId: accountId,
      path: path,
      name: name,
      displayPath: displayPath,
      unreadCount: 0,
      totalCount: 0,
    );

Email _emailWith({
  String id = 'acc-1:42',
  String mailboxPath = 'INBOX',
  String? messageId = '<msg-1@example.com>',
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: mailboxPath,
      uid: 42,
      subject: 'Hello world',
      receivedAt: DateTime(2024, 6),
      sentAt: DateTime(2024, 6),
      from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
      to: const [EmailAddress(email: 'alice@example.com')],
      cc: const [],
      isSeen: false,
      isFlagged: false,
      hasAttachment: false,
      messageId: messageId,
    );

// Builds a minimal app whose initial location is the undo log detail screen
// for [action]. A placeholder email-detail route records its visit so the
// test can assert which path the tap navigated to.
Widget _buildApp({
  required UndoAction action,
  required FakeEmailRepository emailRepo,
  List<Mailbox> mailboxes = const [],
  ValueNotifier<String?>? lastEmailRoute,
}) {
  final router = GoRouter(
    initialLocation: '/undo-detail',
    routes: [
      GoRoute(
        path: '/undo-detail',
        builder: (ctx, state) => UndoLogDetailScreen(action: action),
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
      emailRepositoryProvider.overrideWithValue(emailRepo),
      mailboxRepositoryProvider
          .overrideWithValue(FakeMailboxRepository(mailboxes)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('UndoLogDetailScreen email row tap', () {
    testWidgets('navigates to the current location returned by lookup', (
      tester,
    ) async {
      // Original row recorded INBOX/42; after the move it now lives in
      // Archive with a fresh UID — the lookup is what bridges that gap.
      final original = _emailWith();
      final current = _emailWith(id: 'acc-1:77', mailboxPath: 'Archive');
      final lastRoute = ValueNotifier<String?>(null);

      await tester.pumpWidget(
        _buildApp(
          action: _action(originalEmails: [original]),
          emailRepo: _LookupEmailRepository(current),
          lastEmailRoute: lastRoute,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Hello world'));
      await tester.pumpAndSettle();

      expect(find.text('email-detail-route'), findsOneWidget);
      expect(
        lastRoute.value,
        '/accounts/acc-1/mailboxes/Archive/emails/acc-1%3A77',
      );
    });

    testWidgets('shows snackbar when lookup returns null', (tester) async {
      final original = _emailWith();
      final lastRoute = ValueNotifier<String?>(null);

      await tester.pumpWidget(
        _buildApp(
          action: _action(originalEmails: [original]),
          emailRepo: _LookupEmailRepository(null),
          lastEmailRoute: lastRoute,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Hello world'));
      await tester.pump();

      expect(
        find.textContaining('Email no longer exists'),
        findsOneWidget,
      );
      expect(lastRoute.value, isNull);
      expect(find.text('email-detail-route'), findsNothing);
    });

    testWidgets('shows snackbar when email has no Message-ID', (tester) async {
      final original = _emailWith(messageId: null);
      final lastRoute = ValueNotifier<String?>(null);

      await tester.pumpWidget(
        _buildApp(
          action: _action(originalEmails: [original]),
          // Lookup would succeed if called, but with no Message-ID the
          // tap handler must short-circuit before reaching it.
          emailRepo: _LookupEmailRepository(_emailWith()),
          lastEmailRoute: lastRoute,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Hello world'));
      await tester.pump();

      expect(find.textContaining('no Message-ID'), findsOneWidget);
      expect(lastRoute.value, isNull);
      expect(find.text('email-detail-route'), findsNothing);
    });
  });

  group('UndoLogDetailScreen folder resolution', () {
    testWidgets('resolves JMAP-style paths to their mailbox displayPath', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          action: _action(
            originalEmails: [_emailWith()],
            sourceMailboxPath: 'a',
            destinationMailboxPath: 'b',
          ),
          emailRepo: FakeEmailRepository(),
          mailboxes: [
            _mailbox(path: 'a', name: 'Inbox', displayPath: 'Inbox'),
            _mailbox(
              path: 'b',
              name: '2026',
              displayPath: 'Archive/2026',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Archive/2026'), findsOneWidget);
      // Raw IDs no longer surface as subtitles once resolved.
      expect(find.widgetWithText(ListTile, 'a'), findsNothing);
      expect(find.widgetWithText(ListTile, 'b'), findsNothing);
    });

    testWidgets('falls back to the raw path when the mailbox is unknown', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          action: _action(
            originalEmails: [_emailWith()],
            sourceMailboxPath: 'gone',
            destinationMailboxPath: null,
          ),
          emailRepo: FakeEmailRepository(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('gone'), findsOneWidget);
    });
  });

  group('UndoLogDetailScreen missing originalEmails', () {
    testWidgets('fetches headers by id when originalEmails is empty', (
      tester,
    ) async {
      final fetched = _emailWith(id: 'acc-1:99');
      await tester.pumpWidget(
        _buildApp(
          action: _action(
            originalEmails: const [],
            emailIds: const ['acc-1:99'],
          ),
          emailRepo: FakeEmailRepository(emails: [fetched]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hello world'), findsOneWidget);
      expect(find.textContaining('details not available'), findsNothing);
    });

    testWidgets('keeps the fallback text when no headers can be fetched', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          action: _action(
            originalEmails: const [],
            emailIds: const ['acc-1:missing'],
          ),
          emailRepo: FakeEmailRepository(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('details not available'), findsOneWidget);
    });
  });
}
