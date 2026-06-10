import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
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
  String accountId = 'acc-1',
}) =>
    UndoAction(
      id: 'undo-1',
      accountId: accountId,
      type: UndoType.move,
      emailIds: originalEmails.map((e) => e.id).toList(),
      sourceMailboxPath: 'INBOX',
      destinationMailboxPath: 'Archive',
      originalEmails: originalEmails,
      timestamp: DateTime(2024, 6),
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
}
