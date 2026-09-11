import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/draft.dart';
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
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
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

    testWidgets('prefills To and Subject when provided as constructor params', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(
            prefillTo: 'bob@example.com',
            prefillSubject: 'Re: Hello',
          ),
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
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

    testWidgets('shows static From field when one account is loaded', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice <alice@example.com>'), findsOneWidget);
    });

    testWidgets('shows From dropdown when multiple accounts are loaded', (
      tester,
    ) async {
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
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    testWidgets(
      'does not auto-select an account with several configured, and '
      'blocks send until one is chosen (#463)',
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
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
              draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Neither account is pre-selected — the "From" hint is shown.
        expect(find.text('Select an account'), findsOneWidget);
        expect(find.text('Alice <alice@example.com>'), findsNothing);
        expect(find.text('Bob <bob@example.com>'), findsNothing);

        // Sending without a choice is blocked with a prompt.
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        expect(find.text('Select an account first'), findsOneWidget);

        // Let the SnackBar auto-dismiss so no timer leaks into teardown.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('appends the account signature on a new message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(),
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kSignedAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final body = tester.widget<TextField>(
        find
            .descendant(
              of: find.byType(TextFormField),
              matching: find.byType(TextField),
            )
            .last,
      );
      expect(body.controller!.text, '\n\nCheers,\nAlice');
    });

    testWidgets('inserts the signature above the quoted text on a reply', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(
            replyToEmailId: 'e1',
            prefillBody: '> quoted original',
          ),
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kSignedAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final body = tester.widget<TextField>(
        find
            .descendant(
              of: find.byType(TextFormField),
              matching: find.byType(TextField),
            )
            .last,
      );
      expect(body.controller!.text, 'Cheers,\nAlice\n\n> quoted original');
    });

    testWidgets('restores saved draft when no prefill is provided', (
      tester,
    ) async {
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
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
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

    testWidgets(
      'keeps From matching the inbox account and ignores another '
      "account's new-message draft (#753)",
      (tester) async {
        // Same address reachable via two accounts (IMAP + JMAP), distinct ids.
        const imapAccount = Account(
          id: 'imap-1',
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );
        const jmapAccount = Account(
          id: 'jmap-1',
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );
        // A new-message draft left behind by a previous JMAP compose.
        final fakeDrafts = FakeDraftRepository();
        await fakeDrafts.saveDraft(
          accountId: 'jmap-1',
          toText: 'carol@example.com',
          ccText: '',
          subjectText: 'JMAP draft',
          bodyText: 'from jmap',
        );

        await tester.pumpWidget(
          _buildDirect(
            // Compose opened from the IMAP inbox.
            screen: const ComposeScreen(accountId: 'imap-1'),
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([imapAccount, jmapAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
              draftRepositoryProvider.overrideWithValue(fakeDrafts),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // From stays on the IMAP account; the JMAP draft is not restored.
        final dropdown = tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        );
        expect(dropdown.initialValue, 'imap-1');
        expect(find.widgetWithText(TextFormField, 'JMAP draft'), findsNothing);
      },
    );

    testWidgets('discard deletes the restored draft and pops', (tester) async {
      final fakeDrafts = _RecordingDraftRepository();
      final saved = await _seedRestoredDraft(fakeDrafts);
      final router = _homeAndCompose();
      await _pumpComposeFromHome(tester, router: router, drafts: fakeDrafts);

      // The saved draft has been restored into the fields.
      expect(
        find.widgetWithText(TextFormField, 'Restored subject'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Discard draft'));
      await tester.pumpAndSettle();

      // Draft is gone and we are back on the home screen.
      expect(fakeDrafts.deleted, [saved.id]);
      expect(await fakeDrafts.getDraft(saved.id), isNull);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('Compose'), findsNothing);
    });

    testWidgets('discard with no saved draft just pops', (tester) async {
      final fakeDrafts = _RecordingDraftRepository();
      final router = _homeAndCompose();
      await _pumpComposeFromHome(tester, router: router, drafts: fakeDrafts);

      await tester.tap(find.byTooltip('Discard draft'));
      await tester.pumpAndSettle();

      // Nothing was saved yet, so nothing is deleted — we simply leave.
      expect(fakeDrafts.deleted, isEmpty);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('Compose'), findsNothing);
    });

    testWidgets('discard does not let dispose re-save the draft', (
      tester,
    ) async {
      final fakeDrafts = _RecordingDraftRepository();
      final saved = await _seedRestoredDraft(fakeDrafts);
      final router = _homeAndCompose();
      await _pumpComposeFromHome(tester, router: router, drafts: fakeDrafts);

      // Dirty the draft so the dispose flush would otherwise fire.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Restored subject'),
        'Edited subject',
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Discard draft'));
      await tester.pumpAndSettle();

      // The row stays deleted — dispose did not resurrect it.
      expect(await fakeDrafts.getDraft(saved.id), isNull);
      expect(await fakeDrafts.findDraft(), isNull);
    });
  });
}

/// A [FakeDraftRepository] that records which draft ids were deleted so tests
/// can assert on the discard flow.
class _RecordingDraftRepository extends FakeDraftRepository {
  final List<int> deleted = [];

  @override
  Future<void> deleteDraft(int id) async {
    deleted.add(id);
    return super.deleteDraft(id);
  }
}

/// Seeds the canonical restored draft the discard tests assert on.
Future<SavedDraft> _seedRestoredDraft(FakeDraftRepository drafts) =>
    drafts.saveDraft(
      toText: 'carol@example.com',
      ccText: '',
      subjectText: 'Restored subject',
      bodyText: 'Draft body',
    );

/// Pumps the compose screen reached from a home route so discard can pop back.
Future<void> _pumpComposeFromHome(
  WidgetTester tester, {
  required GoRouter router,
  required FakeDraftRepository drafts,
}) async {
  await tester.pumpWidget(_buildRouter(router: router, drafts: drafts));
  await tester.pumpAndSettle();
  unawaited(router.push('/compose'));
  await tester.pumpAndSettle();
}

/// A router with a home screen under a compose route so [context.pop()] has
/// somewhere to land.
GoRouter _homeAndCompose() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (ctx, state) =>
              const Scaffold(body: Center(child: Text('home'))),
        ),
        GoRoute(
          path: '/compose',
          builder: (ctx, state) => const ComposeScreen(),
        ),
      ],
    );

Widget _buildRouter({
  required GoRouter router,
  required FakeDraftRepository drafts,
}) {
  return ProviderScope(
    overrides: [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([kTestAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      draftRepositoryProvider.overrideWithValue(drafts),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
    ),
  );
}

/// Builds [screen] inside a minimal GoRouter so [context.pop()] works, without
/// going through [buildApp]'s full route tree.
Widget _buildDirect({
  required Widget screen,
  required List<Override> overrides,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [GoRoute(path: '/', builder: (ctx, state) => screen)],
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
