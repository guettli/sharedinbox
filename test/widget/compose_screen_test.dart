import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

void main() {
  group('ComposeScreen', () {
    testWidgets('renders To, Cc, Subject and Body fields', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: _composeOverrides(),
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
          overrides: _composeOverrides(),
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
          overrides: _composeOverrides(),
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
          overrides: _composeOverrides(accounts: const [kTestAccount, second]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    // Regression for the row-overflow class of #965, here via the dropdown.
    // DropdownButton sizes itself from the WIDEST ITEM, not the selected one,
    // so this overflowed by 426px on a real phone at font_scale 2.0 while the
    // short "Select an account" hint was the thing on screen — the long item
    // the user had not opened yet was setting the width.
    //
    // This pins isExpanded only. selectedItemBuilder is not pinned: with the
    // mutation verified to have actually applied, the closed button measures
    // 80px either way, so nothing here can tell them apart. It is kept because
    // the menu can never be wider than the button, so truncating the items
    // instead would leave the user choosing between unreadable addresses.
    testWidgets('From dropdown does not overflow at large text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400); // 360x800 logical
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      // A realistic display-name-plus-address, which is what the item renders.
      const longAccount = Account(
        id: 'acc-2',
        displayName: 'Code8Test',
        email: 'code8@thomas-guettler.de',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: _composeOverrides(
            accounts: const [kTestAccount, longAccount],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Prove the scale reached the widget; without it the row fits and this
      // would pass against the bug.
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(DropdownButtonFormField<String>)),
      );
      expect(scaler.scale(14), greaterThan(16));

      // What pins the fix is the reported RenderFlex overflow surfacing
      // here. A width assertion would be tautological: a vertical sliver
      // hands its child a tight cross-axis width, so the field measures 328
      // no matter what the button does.
      expect(tester.takeException(), isNull);
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
            overrides: _composeOverrides(
              accounts: const [kTestAccount, second],
            ),
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

    testWidgets(
      'queues then sends the message immediately and shows the outcome (#755)',
      (tester) async {
        final email = FakeEmailRepository()
          ..sendNowResult = const SendNowResult(SendNowOutcome.sent);
        await _pumpComposeAndSend(tester, email: email);

        // The draft was queued and then sent right away (not left for the next
        // IDLE cycle), and the concrete result is surfaced to the user.
        expect(email.sentEmailAccountId, kTestAccount.id);
        expect(
          email.sendNowRowIds,
          isNotEmpty,
          reason: 'compose must attempt the send now, not just enqueue it',
        );
        expect(find.text('Message sent'), findsOneWidget);
      },
    );

    testWidgets(
      'a reply carries In-Reply-To and References to the original',
      (tester) async {
        // Without these the recipient's client cannot thread the answer, and
        // neither can this app once the copy in Sent syncs back.
        final email = FakeEmailRepository(emails: [_originalEmail]);
        await _pumpComposeAndSend(tester, email: email, replyToEmailId: 'orig');

        final draft = email.sentEmailDraft!;
        expect(draft.inReplyTo, 'reply-1@example.com');
        expect(draft.references, ['root@example.com', 'reply-1@example.com']);
      },
    );

    testWidgets(
      'a reply resumed from its draft alone is still sent threaded',
      (tester) async {
        // Opened from the drafts list the route carries only the draftId, so
        // the link to the original has to come from the saved draft.
        final drafts = FakeDraftRepository();
        final saved = await drafts.saveDraft(
          accountId: kTestAccount.id,
          replyToEmailId: 'orig',
          toText: 'alice@example.com',
          ccText: '',
          subjectText: 'Re: Project kickoff',
          bodyText: 'Draft body',
        );
        final email = FakeEmailRepository(emails: [_originalEmail]);
        final router = _homeAndCompose();
        await tester.pumpWidget(
          _wrap(
            router: router,
            overrides: _composeOverrides(drafts: drafts, email: email),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(router.push('/compose', extra: {'draftId': saved.id}));
        await tester.pumpAndSettle();

        // An edit re-saves the draft; it must stay a reply draft.
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Draft body'),
          'Edited body',
        );
        await tester.pump(const Duration(seconds: 3));
        expect((await drafts.getDraft(saved.id))?.replyToEmailId, 'orig');
        // Let the "Draft saved" indicator's hide timer run out.
        await tester.pump(const Duration(seconds: 2));

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();

        final draft = email.sentEmailDraft!;
        expect(draft.inReplyTo, 'reply-1@example.com');
        expect(draft.references, ['root@example.com', 'reply-1@example.com']);
      },
    );

    testWidgets(
      'a reply whose original cannot be read is sent unthreaded',
      (tester) async {
        final email = _ThrowingGetEmailRepository();
        await _pumpComposeAndSend(tester, email: email, replyToEmailId: 'orig');

        final draft = email.sentEmailDraft!;
        expect(draft.inReplyTo, isNull);
        expect(draft.references, isEmpty);
        expect(find.textContaining('Queue failed'), findsNothing);
      },
    );

    testWidgets(
      'surfaces a failed direct send with its reason (#755)',
      (tester) async {
        final email = FakeEmailRepository()
          ..sendNowResult = const SendNowResult(
            SendNowOutcome.permanentlyFailed,
            message: 'SMTP rejected: mailbox full',
          );
        await _pumpComposeAndSend(tester, email: email);

        expect(
          find.text('Send failed: SMTP rejected: mailbox full'),
          findsOneWidget,
        );
      },
    );

    testWidgets('appends the account signature on a new message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(),
          overrides: _composeOverrides(accounts: const [kSignedAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(_bodyText(tester), '\n\nCheers,\nAlice');
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
          overrides: _composeOverrides(accounts: const [kSignedAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(_bodyText(tester), 'Cheers,\nAlice\n\n> quoted original');
    });

    testWidgets('starts blank even when a saved draft exists (#1047)', (
      tester,
    ) async {
      final fakeDrafts = FakeDraftRepository();
      await _seedRestoredDraft(fakeDrafts);
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(),
          overrides: _composeOverrides(drafts: fakeDrafts),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'carol@example.com'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextFormField, 'Restored subject'),
        findsNothing,
      );
      expect(_bodyText(tester), isEmpty);
    });

    testWidgets('restores the draft passed by draftId', (tester) async {
      final fakeDrafts = FakeDraftRepository();
      final saved = await _seedRestoredDraft(fakeDrafts);
      await tester.pumpWidget(
        _buildDirect(
          screen: ComposeScreen(draftId: saved.id),
          overrides: _composeOverrides(drafts: fakeDrafts),
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
      expect(_bodyText(tester), 'Draft body');
    });

    testWidgets('typing before a slow restore is not overwritten (#1047)', (
      tester,
    ) async {
      final fakeDrafts = _SlowDraftRepository();
      final saved = await _seedRestoredDraft(fakeDrafts);
      await tester.pumpWidget(
        _buildDirect(
          screen: ComposeScreen(draftId: saved.id),
          overrides: _composeOverrides(drafts: fakeDrafts),
        ),
      );
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Subject'),
        'Typed subject',
      );
      await tester.pump();

      fakeDrafts.release.complete();
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'Typed subject'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'carol@example.com'),
        findsNothing,
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
            overrides: _composeOverrides(
              accounts: const [imapAccount, jmapAccount],
              drafts: fakeDrafts,
            ),
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
      final saved = await _pumpRestoredDraftFromHome(tester, fakeDrafts);

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
      final saved = await _pumpRestoredDraftFromHome(tester, fakeDrafts);

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
      expect(await fakeDrafts.listNewMessageDrafts(), isEmpty);
    });
  });
}

/// The message the reply tests answer: itself a reply to `root@example.com`.
final _originalEmail = Email(
  id: 'orig',
  accountId: kTestAccount.id,
  mailboxPath: 'INBOX',
  uid: 1,
  subject: 'Re: Project kickoff',
  receivedAt: DateTime(2026, 10, 18),
  from: const [EmailAddress(email: 'alice@example.com')],
  to: [EmailAddress(email: kTestAccount.email)],
  cc: const [],
  isSeen: true,
  isFlagged: false,
  hasAttachment: false,
  messageId: 'reply-1@example.com',
  inReplyTo: 'root@example.com',
  references: 'root@example.com',
);

/// A [FakeEmailRepository] whose [getEmail] fails, as a broken local store
/// would.
class _ThrowingGetEmailRepository extends FakeEmailRepository {
  @override
  Future<Email?> getEmail(String emailId) async =>
      throw StateError('database is locked');
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

/// A [FakeDraftRepository] whose [getDraft] blocks until [release] completes,
/// so a test can type while a draft restore is still in flight.
class _SlowDraftRepository extends FakeDraftRepository {
  final Completer<void> release = Completer<void>();

  @override
  Future<SavedDraft?> getDraft(int id) async {
    await release.future;
    return super.getDraft(id);
  }
}

/// The four repository overrides every compose test needs: an account list, a
/// draft store, and empty mailbox/email fakes. Vary [accounts] or [drafts] to
/// change what the screen sees; both default to the single-account, empty-draft
/// setup most tests want.
List<Override> _composeOverrides({
  List<Account> accounts = const [kTestAccount],
  FakeDraftRepository? drafts,
  FakeEmailRepository? email,
  bool Function(String accountId)? syncNow,
}) {
  return [
    accountRepositoryProvider.overrideWithValue(
      FakeAccountRepository(accounts),
    ),
    mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
    emailRepositoryProvider.overrideWithValue(email ?? FakeEmailRepository()),
    draftRepositoryProvider.overrideWithValue(drafts ?? FakeDraftRepository()),
    if (syncNow != null) syncNowProvider.overrideWithValue(syncNow),
  ];
}

/// Reads the compose body text — the last [TextField] nested inside a
/// [TextFormField] on the screen.
String _bodyText(WidgetTester tester) {
  final body = tester.widget<TextField>(
    find
        .descendant(
          of: find.byType(TextFormField),
          matching: find.byType(TextField),
        )
        .last,
  );
  return body.controller!.text;
}

/// Seeds the canonical restored draft the discard tests assert on.
Future<SavedDraft> _seedRestoredDraft(FakeDraftRepository drafts) =>
    drafts.saveDraft(
      toText: 'carol@example.com',
      ccText: '',
      subjectText: 'Restored subject',
      bodyText: 'Draft body',
    );

/// Seeds the canonical restored draft and opens it in compose (by draftId)
/// from a home route — the shared setup for the discard-a-restored-draft tests.
Future<SavedDraft> _pumpRestoredDraftFromHome(
  WidgetTester tester,
  FakeDraftRepository drafts,
) async {
  final saved = await _seedRestoredDraft(drafts);
  await _pumpComposeFromHome(
    tester,
    router: _homeAndCompose(),
    drafts: drafts,
    draftId: saved.id,
  );
  return saved;
}

/// Pumps compose from a home route, fills in a recipient and taps Send —
/// the shared setup for the direct-send (#755) tests, which differ only in
/// the [email] fake's configured outcome.
Future<void> _pumpComposeAndSend(
  WidgetTester tester, {
  required FakeEmailRepository email,
  String? replyToEmailId,
}) async {
  final router = _homeAndCompose();
  await tester.pumpWidget(
    _wrap(router: router, overrides: _composeOverrides(email: email)),
  );
  await tester.pumpAndSettle();
  unawaited(router.push('/compose', extra: {'replyToEmailId': replyToEmailId}));
  await tester.pumpAndSettle();

  await tester.enterText(
    find.widgetWithText(TextFormField, 'To'),
    'bob@example.com',
  );
  await tester.pump();

  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
}

/// Pumps the compose screen reached from a home route so discard can pop back.
Future<void> _pumpComposeFromHome(
  WidgetTester tester, {
  required GoRouter router,
  required FakeDraftRepository drafts,
  int? draftId,
}) async {
  await tester.pumpWidget(_buildRouter(router: router, drafts: drafts));
  await tester.pumpAndSettle();
  unawaited(router.push('/compose', extra: {'draftId': draftId}));
  await tester.pumpAndSettle();
}

/// A router with a home screen under a compose route so [context.pop()] has
/// somewhere to land. The scaffolding is shared with the other tests that need
/// it (`homeAndComposeRouter` in helpers.dart); only the compose builder differs.
GoRouter _homeAndCompose() => homeAndComposeRouter(
      compose: (state) {
        final extra = state.extra as Map<String, dynamic>?;
        return ComposeScreen(
          draftId: extra?['draftId'] as int?,
          replyToEmailId: extra?['replyToEmailId'] as String?,
        );
      },
    );

Widget _buildRouter({
  required GoRouter router,
  required FakeDraftRepository drafts,
}) =>
    _wrap(router: router, overrides: _composeOverrides(drafts: drafts));

/// Builds [screen] inside a minimal GoRouter so [context.pop()] works, without
/// going through [buildApp]'s full route tree.
Widget _buildDirect({
  required Widget screen,
  required List<Override> overrides,
}) =>
    _wrap(
      router: GoRouter(
        initialLocation: '/',
        routes: [GoRoute(path: '/', builder: (ctx, state) => screen)],
      ),
      overrides: overrides,
    );

/// Wraps [router] in a [ProviderScope] and a themed [MaterialApp.router] —
/// the shared shell for [_buildRouter] and [_buildDirect].
Widget _wrap({
  required GoRouter router,
  required List<Override> overrides,
}) {
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
