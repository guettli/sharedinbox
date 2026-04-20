import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

void main() {
  group('ComposeScreen', () {
    testWidgets('renders To, Cc, Subject and Body fields', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('To'), findsOneWidget);
      expect(find.text('Cc'), findsOneWidget);
      expect(find.text('Subject'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });

    testWidgets('prefills To and Subject when provided as constructor params',
        (tester) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(
            prefillTo: 'bob@example.com',
            prefillSubject: 'Re: Hello',
          ),
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'bob@example.com'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'Re: Hello'), findsOneWidget);
    });

    testWidgets('shows static From field when one account is loaded',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice <alice@example.com>'), findsOneWidget);
    });

    testWidgets('shows From dropdown when multiple accounts are loaded',
        (tester) async {
      const second = Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount, second]),
            ),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    testWidgets('restores saved draft when no prefill is provided',
        (tester) async {
      final fakeDrafts = FakeDraftRepository();
      await fakeDrafts.saveDraft(
        toText: 'carol@example.com',
        ccText: '',
        subjectText: 'Restored subject',
        bodyText: 'Draft body',
      );
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(),
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(fakeDrafts),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'carol@example.com'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'Restored subject'),
        findsOneWidget,
      );
    });
  });
}

/// Builds [screen] inside a minimal GoRouter so [context.pop()] works, without
/// going through [buildApp]'s full route tree.
Widget _buildDirect({
  required Widget screen,
  required List<Override> overrides,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (ctx, state) => screen),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
    ),
  );
}
