import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

void main() {
  group('attachments are kept with the draft (#955)', () {
    late Directory dir;
    late File notes;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('compose_attachments');
      notes = File('${dir.path}/notes.txt')..writeAsStringSync('notes');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// Lets Compose's real file-system calls (stat) complete.
    Future<void> settleFileIo(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<GoRouter> pumpHome(
      WidgetTester tester,
      FakeDraftRepository drafts,
      FakeEmailRepository email,
    ) async {
      final router = _homeAndCompose();
      await tester.pumpWidget(
        _wrap(
          router: router,
          overrides: [
            ..._composeOverrides(drafts: drafts, email: email),
            pickAttachmentFilesProvider.overrideWithValue(
              () async => [(path: notes.path, name: 'notes.txt')],
            ),
            // SnackBars are mirrored into the app log; the real file-system
            // calls below would otherwise let it open the real database.
            appLogRepositoryProvider.overrideWithValue(
              const NoOpAppLogRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('attach, leave, reopen: the attachment is still there', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final drafts = FakeDraftRepository();
      final email = FakeEmailRepository();
      final router = await pumpHome(tester, drafts, email);
      unawaited(router.push('/compose'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add attachment'));
      await settleFileIo(tester);
      expect(find.text('notes.txt'), findsOneWidget);

      // Attaching alone is an edit: leaving saves the draft, no question.
      await tester.tap(find.byType(BackButton));
      await settleFileIo(tester);
      expect(find.text('Discard attachments?'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      final saved = (await drafts.getDraft(drafts.savedIds.single))!;
      expect(saved.attachments.map((a) => a.filename), ['notes.txt']);
      expect(saved.attachments.single.contentType, 'text/plain');
      expect(saved.attachments.single.size, 5);

      unawaited(router.push('/compose', extra: {'draftId': saved.id}));
      await settleFileIo(tester);
      expect(find.text('Attachments'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);

      // And it goes out with the message.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'To'),
        'bob@example.com',
      );
      await tester.tap(find.byIcon(Icons.send));
      await settleFileIo(tester);
      expect(email.sentEmailDraft?.attachmentFilePaths, [notes.path]);
    });

    testWidgets('removing the attachment is saved too', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final drafts = FakeDraftRepository();
      final saved = await drafts.saveDraft(
        toText: 'carol@example.com',
        ccText: '',
        subjectText: 'With file',
        bodyText: 'Body',
        attachments: [
          DraftAttachment(
            path: notes.path,
            filename: 'notes.txt',
            contentType: 'text/plain',
            size: 5,
          ),
        ],
      );
      final router = await pumpHome(tester, drafts, FakeEmailRepository());
      unawaited(router.push('/compose', extra: {'draftId': saved.id}));
      await settleFileIo(tester);

      await tester.tap(find.byTooltip('Remove'));
      await tester.pump(const Duration(seconds: 3));
      await settleFileIo(tester);
      // Past the "Saved" badge's timer.
      await tester.pump(const Duration(seconds: 3));

      expect((await drafts.getDraft(saved.id))!.attachments, isEmpty);
      // The user's own file is never deleted.
      expect(notes.existsSync(), isTrue);
    });

    testWidgets('a draft attachment whose file is gone is reported', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final drafts = FakeDraftRepository();
      final saved = await drafts.saveDraft(
        toText: 'carol@example.com',
        ccText: '',
        subjectText: 'With file',
        bodyText: 'Body',
        attachments: [
          DraftAttachment(
            path: '${dir.path}/gone.png',
            filename: 'gone.png',
            contentType: 'image/png',
            size: 3,
          ),
        ],
      );
      final router = await pumpHome(tester, drafts, FakeEmailRepository());
      unawaited(router.push('/compose', extra: {'draftId': saved.id}));
      await settleFileIo(tester);

      expect(find.text('Attachments'), findsNothing);
      expect(
        find.text('Attachment no longer available: gone.png'),
        findsOneWidget,
      );
    });
  });

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
      // Without an explicit enabled flag Flutter's Linux bridge announces
      // the picker as "disabled" (#1180).
      expect(
        tester.getSemantics(find.byType(DropdownButtonFormField<String>)),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    });

    group('From account of a restored draft', () {
      const second = Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );

      Future<(FakeDraftRepository, int)> pumpDraftOf(
        WidgetTester tester,
        String accountId,
      ) async {
        final drafts = FakeDraftRepository();
        final saved = await drafts.saveDraft(
          accountId: accountId,
          toText: 'carol@example.com',
          ccText: '',
          subjectText: 'Draft',
          bodyText: 'Body',
        );
        await tester.pumpWidget(
          _buildDirect(
            screen: ComposeScreen(draftId: saved.id),
            overrides: _composeOverrides(
              accounts: const [kTestAccount, second],
              drafts: drafts,
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (drafts, saved.id);
      }

      testWidgets('a deleted account leaves From unselected', (tester) async {
        // Before, the dropdown got a value missing from its items.
        await pumpDraftOf(tester, 'deleted-account');

        expect(tester.takeException(), isNull);
        expect(find.text('Select an account'), findsOneWidget);
      });

      testWidgets('choosing another account saves the draft under it', (
        tester,
      ) async {
        final (drafts, id) = await pumpDraftOf(tester, kTestAccount.id);

        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(accountFromLabel(second)).last);
        await tester.pumpAndSettle();
        // Auto-save after 2 s, then the "saved" indicator's 2 s.
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));

        expect((await drafts.getDraft(id))?.accountId, 'acc-2');
      });
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

    testWidgets('blocks send while To is empty (#1061)', (tester) async {
      final email = FakeEmailRepository();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/compose',
          overrides: _composeOverrides(email: email),
        ),
      );
      await tester.pumpAndSettle();

      // Whitespace and stray commas do not count as a recipient.
      await tester.enterText(find.widgetWithText(TextFormField, 'To'), ' , ');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Subject'),
        'No recipient',
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(find.text('Add a recipient in To first'), findsOneWidget);
      expect(email.sentEmailAccountId, isNull);
      expect(email.sendNowRowIds, isEmpty);
      expect(find.byType(ComposeScreen), findsOneWidget);

      // Let the SnackBar auto-dismiss so no timer leaks into teardown.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('refuses to send to something that is not an address', (
      tester,
    ) async {
      final email = FakeEmailRepository();
      await _pumpComposeAndSend(
        tester,
        email: email,
        beforeSend: () => tester.enterText(
          find.widgetWithText(TextFormField, 'To'),
          'bob@example.com, not-an-address',
        ),
      );

      // Sending used to drop the bad entry and mail only Bob.
      expect(find.text('Not an email address: not-an-address'), findsOneWidget);
      expect(email.sentEmailAccountId, isNull);
      expect(email.sendNowRowIds, isEmpty);
      expect(find.byType(ComposeScreen), findsOneWidget);

      // Let the SnackBar auto-dismiss so no timer leaks into teardown.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('Bcc is collapsed until its button is tapped (#1126)', (
      tester,
    ) async {
      final email = FakeEmailRepository();
      await _pumpComposeAndSend(
        tester,
        email: email,
        beforeSend: () async {
          // Only the button on the Cc field says "Bcc" so far.
          expect(find.text('Bcc'), findsOneWidget);
          expect(
            find.ancestor(
              of: find.text('Bcc'),
              matching: find.byKey(const Key('compose-show-bcc')),
            ),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('compose-show-bcc')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('compose-show-bcc')), findsNothing);
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Bcc'),
            'Eve <eve@example.com>',
          );
          await tester.pump();
        },
      );

      final draft = email.sentEmailDraft!;
      expect(draft.bcc.map((a) => a.email), ['eve@example.com']);
      expect(draft.bcc.single.name, 'Eve');
      // Bcc never leaks into the visible recipients.
      expect(draft.to.map((a) => a.email), isNot(contains('eve@example.com')));
      expect(draft.cc, isEmpty);
    });

    testWidgets('refuses a Bcc entry that is not an address (#1126)', (
      tester,
    ) async {
      final email = FakeEmailRepository();
      await _pumpComposeAndSend(
        tester,
        email: email,
        beforeSend: () async {
          await tester.tap(find.byKey(const Key('compose-show-bcc')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Bcc'),
            'eve',
          );
          await tester.pump();
        },
      );

      expect(find.text('Not an email address: eve'), findsOneWidget);
      expect(email.sentEmailAccountId, isNull);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('a draft with Bcc restores into an open Bcc field (#1126)', (
      tester,
    ) async {
      final fakeDrafts = FakeDraftRepository();
      final saved = await fakeDrafts.saveDraft(
        toText: 'carol@example.com',
        ccText: '',
        bccText: 'dave@example.com',
        subjectText: 'Restored subject',
        bodyText: 'Draft body',
      );
      await tester.pumpWidget(
        _buildDirect(
          screen: ComposeScreen(draftId: saved.id),
          overrides: _composeOverrides(drafts: fakeDrafts),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'dave@example.com'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('compose-show-bcc')), findsNothing);
    });

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
      'sending right after typing leaves no draft behind',
      (tester) async {
        // Typing and pressing Send within the auto-save delay left the field
        // dirty; when the screen closed, dispose saved the sent message back
        // as a new draft, which then synced to the server's Drafts folder.
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository();
        await _pumpComposeAndSend(tester, email: email, drafts: drafts);

        expect(email.sendNowRowIds, isNotEmpty);
        expect(await drafts.remaining(), isEmpty);
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
      'sending deletes the auto-saved draft and does not write it back',
      (tester) async {
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository();
        await _pumpComposeAndSend(
          tester,
          email: email,
          drafts: drafts,
          beforeSend: () async {
            // Let the auto-save land, then edit again so the field is dirty
            // once more when Send is pressed.
            await tester.pump(const Duration(seconds: 3));
            expect(await drafts.remaining(), hasLength(1));
            await tester.enterText(
              find.widgetWithText(TextFormField, 'Subject'),
              'Final subject',
            );
            await tester.pump();
          },
        );

        expect(await drafts.remaining(), isEmpty);

        // Let the "Draft saved" indicator and the SnackBar time out so no
        // timer leaks into teardown.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'sending a reply deletes its auto-saved draft',
      (tester) async {
        // Reply drafts are hidden from listNewMessageDrafts, so look the row
        // up by id: it must be gone, not merely filtered out.
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository();
        await _pumpComposeAndSend(
          tester,
          email: email,
          drafts: drafts,
          replyToEmailId: 'email-1',
          beforeSend: () async {
            await tester.pump(const Duration(seconds: 3));
            final saved = await drafts.remaining();
            expect(saved, hasLength(1));
            expect(saved.single.replyToEmailId, 'email-1');
            await tester.enterText(
              find.widgetWithText(TextFormField, 'Subject'),
              'Re: hello',
            );
            await tester.pump();
          },
        );

        expect(email.sendNowRowIds, isNotEmpty);
        expect(drafts.savedIds, isNotEmpty);
        expect(await drafts.remaining(), isEmpty);

        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'sending while an auto-save is still writing leaves no draft behind',
      (tester) async {
        // The auto-save had started but not yet returned the new row's id
        // when Send was pressed: send saw no draft to delete, and the save
        // then landed after the screen closed.
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository();
        final gate = await _pumpComposeWithHeldSave(
          tester,
          drafts: drafts,
          email: email,
        );
        expect(drafts.pendingSaves, 1);

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump();
        gate.complete();
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();

        expect(email.sendNowRowIds, isNotEmpty);
        expect(drafts.savedIds, isNotEmpty);
        expect(await drafts.remaining(), isEmpty);
        expect(find.text('home'), findsOneWidget);
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
      'a failed in-flight auto-save does not fail the send',
      (tester) async {
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository();
        final gate = await _pumpComposeWithHeldSave(
          tester,
          drafts: drafts,
          email: email,
        );

        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        gate.completeError(StateError('disk full'));
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('Queue failed'), findsNothing);
        expect(find.text('Message sent'), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
      },
    );

    testWidgets(
      'a send that throws after queueing closes instead of inviting a resend',
      (tester) async {
        final drafts = _TrackingDraftRepository();
        final email = FakeEmailRepository()
          ..sendNowError = StateError('No password stored');
        await _pumpComposeAndSend(tester, email: email, drafts: drafts);

        expect(find.textContaining('Queue failed'), findsNothing);
        expect(find.textContaining('Queued — will retry'), findsOneWidget);
        expect(find.text('home'), findsOneWidget);
        expect(await drafts.remaining(), isEmpty);

        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
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

      expect(_bodyText(tester), '\n\nCheers,\nAlice\n\n> quoted original');
    });

    testWidgets(
      'Tab from Subject into the body types above the signature',
      (tester) async {
        await tester.pumpWidget(
          _buildDirect(
            screen: const ComposeScreen(),
            overrides: _composeOverrides(accounts: const [kSignedAccount]),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextFormField, 'Subject'));
        await tester.pump();
        await _typeAtCursor(tester, 'Hello');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await _typeAtCursor(tester, 'Typed after tab');

        expect(_bodyText(tester), 'Typed after tab\n\nCheers,\nAlice');
      },
    );

    testWidgets(
      'focusing a reply body types above the signature and the quote',
      (tester) async {
        await tester.pumpWidget(
          _buildDirect(
            screen: const ComposeScreen(
              replyToEmailId: 'e1',
              prefillTo: 'bob@example.com',
              prefillBody: '\n\n> quoted original',
            ),
            overrides: _composeOverrides(accounts: const [kSignedAccount]),
          ),
        );
        await tester.pumpAndSettle();

        _bodyFocus(tester).requestFocus();
        await tester.pumpAndSettle();
        await _typeAtCursor(tester, 'Thanks!');

        expect(
          _bodyText(tester),
          'Thanks!\n\nCheers,\nAlice\n\n> quoted original',
        );
      },
    );

    testWidgets('a forward is typed above the quote, signature after it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(
            prefillBody: '\n\n— On x, y wrote:\n> q',
          ),
          overrides: _composeOverrides(accounts: const [kSignedAccount]),
        ),
      );
      await tester.pumpAndSettle();

      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, 'FYI');

      expect(
        _bodyText(tester),
        'FYI\n\n— On x, y wrote:\n> q\n\nCheers,\nAlice',
      );
    });

    testWidgets('a prefilled mailto body is continued before the signature', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(prefillBody: 'Hello'),
          overrides: _composeOverrides(accounts: const [kSignedAccount]),
        ),
      );
      await tester.pumpAndSettle();

      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, ' world');

      expect(_bodyText(tester), 'Hello world\n\nCheers,\nAlice');
    });

    testWidgets('switching account after focusing keeps the cursor on top', (
      tester,
    ) async {
      await _pumpTwoSignedAccounts(tester);

      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _switchToBob(tester);
      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, 'Typed');

      expect(_bodyText(tester), 'Typed\n\nBye,\nBob');
    });

    testWidgets('switching account after typing keeps the user cursor', (
      tester,
    ) async {
      await _pumpTwoSignedAccounts(
        tester,
        replyToEmailId: 'e1',
        prefillBody: '\n\n> ab',
      );

      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, 'Hi');
      // The user clicks into the quote, between "a" and "b".
      final ctrl = _bodyController(tester);
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length - 1);
      await _switchToBob(tester);
      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, 'X');

      expect(_bodyText(tester), 'Hi\n\nBye,\nBob\n\n> aXb');
    });

    testWidgets('keeps the cursor where the user typed in the body', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(),
          overrides: _composeOverrides(accounts: const [kSignedAccount]),
        ),
      );
      await tester.pumpAndSettle();

      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, 'Hi');
      _bodyFocus(tester).unfocus();
      await tester.pumpAndSettle();
      _bodyFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      await _typeAtCursor(tester, ' there');

      expect(_bodyText(tester), 'Hi there\n\nCheers,\nAlice');
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

    testWidgets('prefilled and restored bodies lose their carriage returns', (
      tester,
    ) async {
      // A mailto body (%0D%0A) or a reply quote of a CRLF mail.
      await tester.pumpWidget(
        _buildDirect(
          screen: const ComposeScreen(prefillBody: 'one\r\ntwo\rthree'),
          overrides: _composeOverrides(),
        ),
      );
      await tester.pumpAndSettle();
      expect(_bodyText(tester), 'one\ntwo\nthree');

      // A draft pulled from the server.
      final drafts = FakeDraftRepository();
      final saved = await drafts.saveDraft(
        toText: '',
        ccText: '',
        subjectText: 'Synced',
        bodyText: 'Hi\r\n\r\n> quoted\r\n',
      );
      await tester.pumpWidget(
        _buildDirect(
          screen: ComposeScreen(draftId: saved.id),
          overrides: _composeOverrides(drafts: drafts),
        ),
      );
      await tester.pumpAndSettle();
      expect(_bodyText(tester), 'Hi\n\n> quoted\n');
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

    testWidgets('discard waits for an in-flight auto-save', (tester) async {
      final fakeDrafts = _TrackingDraftRepository();
      final saved = await _pumpRestoredDraftFromHome(tester, fakeDrafts);

      final gate = fakeDrafts.gate = Completer<void>();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Restored subject'),
        'Edited subject',
      );
      await tester.pump(const Duration(seconds: 3));
      expect(fakeDrafts.pendingSaves, 1);

      await tester.tap(find.byTooltip('Discard draft'));
      await tester.pump();
      gate.complete();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      // The held save did not land after the delete and resurrect the row.
      expect(await fakeDrafts.getDraft(saved.id), isNull);
      expect(find.text('home'), findsOneWidget);
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

/// A [_RecordingDraftRepository] whose saves block on [gate] while one is
/// set, so a test can act while an auto-save is still writing.
class _TrackingDraftRepository extends _RecordingDraftRepository {
  Completer<void>? gate;
  int pendingSaves = 0;

  @override
  Future<void> beforeSave() async {
    final g = gate;
    if (g == null) return;
    pendingSaves++;
    try {
      await g.future;
    } finally {
      pendingSaves--;
    }
  }

  /// The saved rows that still exist, reply drafts included.
  Future<List<SavedDraft>> remaining() async {
    final rows = [for (final id in savedIds) await getDraft(id)];
    return rows.whereType<SavedDraft>().toList();
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

const _kBobAccount = Account(
  id: 'acc-2',
  displayName: 'Bob',
  email: 'bob@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
  signature: 'Bye,\nBob',
);

/// Compose from [kSignedAccount] with [_kBobAccount] as a second choice.
Future<void> _pumpTwoSignedAccounts(
  WidgetTester tester, {
  String? replyToEmailId,
  String? prefillBody,
}) async {
  await tester.pumpWidget(
    _buildDirect(
      screen: ComposeScreen(
        accountId: kSignedAccount.id,
        replyToEmailId: replyToEmailId,
        prefillBody: prefillBody,
      ),
      overrides: _composeOverrides(
        accounts: const [kSignedAccount, _kBobAccount],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Picks [_kBobAccount] in the From dropdown.
Future<void> _switchToBob(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(accountFromLabel(_kBobAccount)).last);
  await tester.pumpAndSettle();
}

TextEditingController _bodyController(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).last).controller;

/// The body field's focus node (the body is the last text field).
FocusNode _bodyFocus(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).last).focusNode;

/// Inserts [text] at the focused field's cursor, as a platform IME does.
Future<void> _typeAtCursor(WidgetTester tester, String text) async {
  final field = tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere((e) => e.focusNode.hasFocus);
  final value = field.controller.value;
  final sel = value.selection;
  final start = sel.isValid ? sel.start : value.text.length;
  final end = sel.isValid ? sel.end : value.text.length;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    ),
  );
  await tester.pump();
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
  FakeDraftRepository? drafts,
  String? replyToEmailId,
  Future<void> Function()? beforeSend,
}) async {
  await _openComposeWithRecipient(
    tester,
    email: email,
    drafts: drafts,
    replyToEmailId: replyToEmailId,
  );
  await tester.pump();
  await beforeSend?.call();

  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
}

/// Opens compose from a home route and types a recipient — the common start
/// of [_pumpComposeAndSend] and [_pumpComposeWithHeldSave].
Future<void> _openComposeWithRecipient(
  WidgetTester tester, {
  required FakeEmailRepository email,
  FakeDraftRepository? drafts,
  String? replyToEmailId,
}) async {
  final router = _homeAndCompose();
  await tester.pumpWidget(
    _wrap(
      router: router,
      overrides: _composeOverrides(email: email, drafts: drafts),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(
    router.push('/compose', extra: {'replyToEmailId': replyToEmailId}),
  );
  await tester.pumpAndSettle();

  await tester.enterText(
    find.widgetWithText(TextFormField, 'To'),
    'bob@example.com',
  );
}

/// Opens a new compose from a home route and types a recipient, so the
/// auto-save starts and then holds on [drafts]' gate. Returns that gate.
Future<Completer<void>> _pumpComposeWithHeldSave(
  WidgetTester tester, {
  required _TrackingDraftRepository drafts,
  required FakeEmailRepository email,
}) async {
  // Nothing saves before the first edit, so the gate can be set up front.
  final gate = drafts.gate = Completer<void>();
  await _openComposeWithRecipient(tester, email: email, drafts: drafts);
  await tester.pump(const Duration(seconds: 3));
  return gate;
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
