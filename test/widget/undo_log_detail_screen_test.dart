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

// FakeEmailRepository subclass that resolves the getEmail-by-id fallback used
// when UndoAction.originalEmails is empty (legacy actions persisted before
// the archive/spam/move handlers started snapshotting headers).
class _GetEmailFallbackRepository extends FakeEmailRepository {
  _GetEmailFallbackRepository(this._byId);

  final Map<String, Email> _byId;

  @override
  Future<Email?> getEmail(String emailId) async => _byId[emailId];
}

UndoAction _action({
  List<Email> originalEmails = const [],
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

Email _emailWith({
  String id = 'acc-1:42',
  String mailboxPath = 'INBOX',
  String? messageId = '<msg-1@example.com>',
  String subject = 'Hello world',
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: mailboxPath,
      uid: 42,
      subject: subject,
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
    testWidgets('renders JMAP displayPath instead of the opaque server id', (
      tester,
    ) async {
      // JMAP: Email.mailboxPath / UndoAction.sourceMailboxPath store the
      // server-side id ("a"), but the UI must show the hierarchical name
      // ("INBOX") — same distinction addressed for the folder picker in #227.
      const inbox = Mailbox(
        id: 'acc-1:a',
        accountId: 'acc-1',
        path: 'a',
        name: 'INBOX',
        displayPath: 'INBOX',
        unreadCount: 0,
        totalCount: 0,
      );
      const archive = Mailbox(
        id: 'acc-1:b',
        accountId: 'acc-1',
        path: 'b',
        name: '2026',
        displayPath: 'Archive/2026',
        unreadCount: 0,
        totalCount: 0,
      );

      await tester.pumpWidget(
        _buildApp(
          action: _action(
            originalEmails: [_emailWith(mailboxPath: 'a')],
            sourceMailboxPath: 'a',
            destinationMailboxPath: 'b',
          ),
          emailRepo: FakeEmailRepository(),
          mailboxes: const [inbox, archive],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsOneWidget);
      expect(find.text('Archive/2026'), findsOneWidget);
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsNothing);
    });

    testWidgets(
      'falls back to the raw path when the mailbox is no longer cached',
      (tester) async {
        // Simulates a folder that was deleted between the undo action being
        // recorded and the detail screen being opened: nothing to resolve,
        // so we show the raw id verbatim rather than blanking the field.
        await tester.pumpWidget(
          _buildApp(
            action: _action(
              originalEmails: [_emailWith(mailboxPath: 'a')],
              sourceMailboxPath: 'a',
              destinationMailboxPath: 'b',
            ),
            emailRepo: FakeEmailRepository(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('a'), findsOneWidget);
        expect(find.text('b'), findsOneWidget);
      },
    );
  });

  group('UndoLogDetailScreen emails section', () {
    testWidgets(
      'falls back to getEmail when originalEmails is empty',
      (tester) async {
        // Legacy actions (persisted before archive/spam/move started
        // snapshotting headers) do not carry originalEmails. As long as the
        // email row still exists we can resolve the subject on the fly.
        final email = _emailWith(subject: 'Legacy subject');

        await tester.pumpWidget(
          _buildApp(
            action: _action(
              emailIds: [email.id],
            ),
            emailRepo: _GetEmailFallbackRepository({email.id: email}),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Legacy subject'), findsOneWidget);
        expect(find.textContaining('details not available'), findsNothing);
      },
    );

    testWidgets(
      'shows the not-available hint when neither originalEmails nor '
      'getEmail returns anything',
      (tester) async {
        // Hard-deleted email + no snapshot → nothing to render, but the
        // count of ids still gives the user a sense of scope.
        await tester.pumpWidget(
          _buildApp(
            action: _action(
              emailIds: const ['acc-1:42', 'acc-1:43'],
            ),
            emailRepo: _GetEmailFallbackRepository(const {}),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('2 email(s)'), findsOneWidget);
        expect(find.textContaining('details not available'), findsOneWidget);
      },
    );
  });
}
