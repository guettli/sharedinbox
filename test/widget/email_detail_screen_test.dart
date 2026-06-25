import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/platform/raw_email_downloader.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

// Fake PathProviderPlatform so _downloadRaw resolves getTemporaryDirectory
// via pure microtasks instead of calling xdg-user-dir.
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => '/tmp';
}

// IOOverrides subclass that stubs File creation so _downloadRaw completes
// without real dart:io — writeAsString becomes a no-op microtask.
base class _FakeIOOverrides extends IOOverrides {
  @override
  File createFile(String path) => _FakeFile(path);
}

// Fake File whose writeAsString is a no-op so _downloadRaw completes without
// real I/O.  Other methods are unused and left to Fake's noSuchMethod handler.
class _FakeFile extends Fake implements File {
  _FakeFile(this._path);
  final String _path;

  @override
  String get path => _path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async =>
      this;
}

// Shared overrides for email detail tests.
List<Override> _overrides({required EmailBody body, Email? email}) => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([kTestAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(emailDetail: email ?? testEmail(), emailBody: body),
      ),
    ];

void main() {
  group('EmailDetailScreen', () {
    testWidgets('shows loading spinner before data arrives', (tester) async {
      // Use a Completer-backed repo so data never arrives during this test.
      final neverRepo = _NeverEmailRepository();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(neverRepo),
          ],
        ),
      );
      // One pump to build the widget tree; future not resolved yet.
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows subject in email header section', (tester) async {
      final email = testEmail(subject: 'Project update');
      const body = EmailBody(
        emailId: 'acc-1:42',
        textBody: 'See attached slides.',
        attachments: [],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(emailDetail: email, emailBody: body),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Subject appears only in the email header section, not in the app bar.
      expect(find.text('Project update'), findsOneWidget);
      expect(find.text('See attached slides.'), findsOneWidget);
    });

    testWidgets('shows from-address in header', (tester) async {
      final email = testEmail();
      const body = EmailBody(
        emailId: 'acc-1:42',
        textBody: 'Hi',
        attachments: [],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(emailDetail: email, emailBody: body),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('bob@example.com'), findsOneWidget);
    });

    testWidgets('shows attachment section when email has attachments', (
      tester,
    ) async {
      final email = testEmail(hasAttachment: true);
      const body = EmailBody(
        emailId: 'acc-1:42',
        textBody: 'Please review.',
        attachments: [
          EmailAttachment(
            filename: 'report.pdf',
            contentType: 'application/pdf',
            size: 204800,
          ),
        ],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(emailDetail: email, emailBody: body),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Attachments'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    });

    testWidgets('Reply All button is not present in app bar', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Reply all'),
        findsNothing,
      );
    });

    testWidgets(
      'Reply on single-recipient email navigates directly to compose',
      (tester) async {
        // testEmail has from=[bob], to=[alice]. After removing alice (own),
        // only bob remains → no dialog, navigate straight to compose.
        final email = testEmail();
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              ..._overrides(
                body: const EmailBody(emailId: 'acc-1:42', attachments: []),
                email: email,
              ),
              draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Reply'),
        );
        await tester.pumpAndSettle();

        // No dialog shown — straight navigation to compose.
        expect(find.text('Reply All'), findsNothing);
      },
    );

    testWidgets('Reply on multi-recipient email shows Reply All dialog', (
      tester,
    ) async {
      // Email with an extra Cc recipient so the dialog is triggered.
      final email = Email(
        id: 'acc-1:42',
        accountId: 'acc-1',
        mailboxPath: 'INBOX',
        uid: 42,
        subject: 'Hello world',
        receivedAt: DateTime(2024, 6),
        sentAt: DateTime(2024, 6),
        from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [EmailAddress(name: 'Carol', email: 'carol@example.com')],
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
            email: email,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Reply'),
      );
      await tester.pumpAndSettle();

      // Dialog must appear with title 'Reply All'.
      expect(find.text('Reply All'), findsOneWidget);
      // Both non-own addresses should be listed in the dialog.
      expect(find.textContaining('bob@example.com'), findsAtLeastNWidgets(1));
      expect(find.textContaining('carol@example.com'), findsAtLeastNWidgets(1));
    });

    testWidgets('Mark as spam is a standalone button, not in popup menu', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Standalone icon button for mark as spam is in the app bar.
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Mark as spam',
        ),
        findsOneWidget,
      );

      // It does NOT appear in the popup menu.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Mark as spam'), findsNothing);
    });

    testWidgets('Mark as spam shows dialog when no junk folder', (
      tester,
    ) async {
      // FakeMailboxRepository has no mailboxes by default → findMailboxByRole
      // returns null → dialog shown.
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Mark as spam',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No spam folder found'), findsOneWidget);
    });

    testWidgets('Archive button is present in app bar', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive'),
        findsOneWidget,
      );
    });

    testWidgets('Archive shows dialog when no archive folder', (tester) async {
      // FakeMailboxRepository has no mailboxes by default → findMailboxByRole
      // returns null → dialog shown.
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive'),
      );
      await tester.pumpAndSettle();

      expect(find.text('No archive folder found'), findsOneWidget);
    });

    testWidgets('Mark as unread is in popup menu, not a standalone button', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No standalone icon button for mark as unread.
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Mark as unread',
        ),
        findsNothing,
      );

      // It appears in the popup menu.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Mark as unread'), findsOneWidget);
    });

    testWidgets('Find similar emails entry appears in popup menu', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Find similar emails'), findsOneWidget);
    });

    testWidgets('Show Raw Email dialog shows size of email', (tester) async {
      // 'A' * 2048 → fmtSize(2048) == '2.0 KB'
      final rawContent = 'A' * 2048;
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: testEmail(),
                emailBody: const EmailBody(
                  emailId: 'acc-1:42',
                  attachments: [],
                ),
                rawRfc822: rawContent,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show Raw Email'));
      await tester.pumpAndSettle();

      expect(find.text('Raw Email'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);
    });

    testWidgets('Download Raw Email closes dialog after download', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: testEmail(),
                emailBody: const EmailBody(
                  emailId: 'acc-1:42',
                  attachments: [],
                ),
                rawRfc822: 'Subject: test\r\n\r\nBody',
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show Raw Email'));
      await tester.pumpAndSettle();

      expect(find.text('Raw Email'), findsOneWidget);

      // Replace path_provider and File I/O with pure-microtask fakes so the
      // entire _downloadRaw → Navigator.pop chain completes within pump loops.
      final prevPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform();
      IOOverrides.global = _FakeIOOverrides();
      addTearDown(() {
        PathProviderPlatform.instance = prevPathProvider;
        IOOverrides.global = null;
      });

      await tester.tap(find.text('Download'));
      // Each pump drains one microtask level: getTemporaryDirectory, then
      // writeAsString, then _downloadRaw return, then Navigator.pop.
      for (var i = 0; i < 10; i++) {
        await tester.pump(Duration.zero);
      }
      await tester.pumpAndSettle();

      // Dialog must be dismissed after download completes.
      expect(find.text('Raw Email'), findsNothing);
      // Non-Android fallback writes to the temp dir, so the SnackBar offers
      // a Share action to hand the file off to another app.
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('Download Raw Email snack bar auto-dismisses', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: testEmail(),
                emailBody: const EmailBody(
                  emailId: 'acc-1:42',
                  attachments: [],
                ),
                rawRfc822: 'Subject: test\r\n\r\nBody',
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show Raw Email'));
      await tester.pumpAndSettle();

      final prevPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform();
      IOOverrides.global = _FakeIOOverrides();
      addTearDown(() {
        PathProviderPlatform.instance = prevPathProvider;
        IOOverrides.global = null;
      });

      await tester.tap(find.text('Download'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(Duration.zero);
      }
      // Settle the snack bar enter animation.
      await tester.pump(const Duration(milliseconds: 500));

      // Snack bar with the Share action must be visible.
      expect(find.text('Share'), findsOneWidget);

      // After the snack bar's duration plus the reverse animation, the snack
      // bar must be gone on its own.
      // Regression test for #113: SnackBar with an action defaults to
      // persist=true, which disables auto-dismiss — explicit persist:false
      // restores duration-based dismissal.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('Share'), findsNothing);
    });

    testWidgets(
      'Download Raw Email on Android writes via MediaStore and shows Open',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  emailDetail: testEmail(subject: 'agenda'),
                  emailBody: const EmailBody(
                    emailId: 'acc-1:42',
                    attachments: [],
                  ),
                  rawRfc822: 'Subject: agenda\r\n\r\nBody',
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Show Raw Email'));
        await tester.pumpAndSettle();

        // Force the Android branch in the downloader and stub the platform
        // channel that would normally write to MediaStore.Downloads.
        final prevIsAndroid = rawEmailIsAndroid;
        rawEmailIsAndroid = () => true;
        String? capturedFilename;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          androidRawEmailChannel,
          (MethodCall call) async {
            if (call.method == 'saveToDownloads') {
              final args = call.arguments as Map<dynamic, dynamic>;
              capturedFilename = args['filename'] as String?;
              return 'content://media/external/downloads/42';
            }
            return null;
          },
        );
        addTearDown(() {
          rawEmailIsAndroid = prevIsAndroid;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            androidRawEmailChannel,
            null,
          );
        });

        await tester.tap(find.text('Download'));
        for (var i = 0; i < 10; i++) {
          await tester.pump(Duration.zero);
        }
        await tester.pumpAndSettle();

        // Channel received the .eml content with a sanitized filename.
        expect(capturedFilename, 'agenda.eml');
        // Dialog must be dismissed after download completes.
        expect(find.text('Raw Email'), findsNothing);
        // SnackBar must show the public Downloads path and an Open action
        // (which, when tapped, registers the file in the system's recents).
        expect(find.text('Saved Download/agenda.eml'), findsOneWidget);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Share'), findsNothing);
      },
    );

    testWidgets('long-press on unsubscribe chip shows URL tooltip', (
      tester,
    ) async {
      final email = testEmail(
        listUnsubscribeHeader: '<https://example.com/unsubscribe>',
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
            email: email,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Unsubscribe'), findsOneWidget);

      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'https://example.com/unsubscribe',
        ),
        findsOneWidget,
      );

      await tester.longPress(find.text('Unsubscribe'));
      await tester.pumpAndSettle();

      expect(find.text('https://example.com/unsubscribe'), findsOneWidget);
    });

    testWidgets('mailto unsubscribe header renders chip with mailto URI', (
      tester,
    ) async {
      final email = testEmail(
        listUnsubscribeHeader: '<mailto:unsub@example.com?subject=unsubscribe>',
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(emailId: 'acc-1:42', attachments: []),
            email: email,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Unsubscribe'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              w.message == 'mailto:unsub@example.com?subject=unsubscribe',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'unsubscribe chip is hidden when header has no usable URI',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader: '<ftp://example.com/u>',
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(
              body: const EmailBody(emailId: 'acc-1:42', attachments: []),
              email: email,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe'), findsNothing);
      },
    );

    testWidgets(
      'tapping unsubscribe shows confirmation dialog; Cancel dismisses it',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader: '<https://example.com/unsubscribe>',
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(
              body: const EmailBody(emailId: 'acc-1:42', attachments: []),
              email: email,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsOneWidget);
        expect(
          find.textContaining('https://example.com/unsubscribe'),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsNothing);
      },
    );

    testWidgets(
      'mailto unsubscribe dialog mentions the recipient address',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader: '<mailto:unsub@example.com>',
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(
              body: const EmailBody(emailId: 'acc-1:42', attachments: []),
              email: email,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsOneWidget);
        expect(
          find.textContaining('unsub@example.com'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'confirming mailto unsubscribe sends the email directly via sendEmail',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader:
              '<mailto:unsub@example.com?subject=unsubscribe-please>',
        );
        final repo = FakeEmailRepository(
          emailDetail: email,
          emailBody: const EmailBody(emailId: 'acc-1:42', attachments: []),
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
        await tester.pumpAndSettle();

        // The email was handed off to the repository, not to an external app.
        expect(repo.sentEmailAccountId, 'acc-1');
        expect(repo.sentEmailDraft, isNotNull);
        expect(repo.sentEmailDraft!.from.email, kTestAccount.email);
        expect(repo.sentEmailDraft!.to.length, 1);
        expect(repo.sentEmailDraft!.to.first.email, 'unsub@example.com');
        expect(repo.sentEmailDraft!.subject, 'unsubscribe-please');

        // Confirmation snack bar is shown.
        expect(find.text('Unsubscribe email sent'), findsOneWidget);
      },
    );

    testWidgets(
      'mailto unsubscribe defaults subject to "unsubscribe" when not in URI',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader: '<mailto:unsub@example.com>',
        );
        final repo = FakeEmailRepository(
          emailDetail: email,
          emailBody: const EmailBody(emailId: 'acc-1:42', attachments: []),
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
        await tester.pumpAndSettle();

        expect(repo.sentEmailDraft!.subject, 'unsubscribe');
        expect(repo.sentEmailDraft!.body, '');
      },
    );

    testWidgets(
      'multiple unsubscribe options show a chooser before launching',
      (tester) async {
        // Header advertises both a mailto and an https option — the user
        // should be asked which one to use instead of one being picked
        // silently.
        final email = testEmail(
          listUnsubscribeHeader:
              '<mailto:unsub@example.com>, <https://example.com/unsubscribe>',
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(
              body: const EmailBody(emailId: 'acc-1:42', attachments: []),
              email: email,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsOneWidget);
        // Both options are offered with their action label and target.
        expect(find.text('Send unsubscribe email'), findsOneWidget);
        expect(find.text('unsub@example.com'), findsOneWidget);
        expect(find.text('Open unsubscribe page'), findsOneWidget);
        expect(find.text('https://example.com/unsubscribe'), findsOneWidget);
      },
    );

    testWidgets(
      'chooser Cancel dismisses the dialog without launching anything',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader:
              '<mailto:unsub@example.com>, <https://example.com/unsubscribe>',
        );
        final repo = FakeEmailRepository(
          emailDetail: email,
          emailBody: const EmailBody(emailId: 'acc-1:42', attachments: []),
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Unsubscribe?'), findsNothing);
        expect(repo.sentEmailDraft, isNull);
      },
    );

    testWidgets(
      'picking mailto from the chooser sends via sendEmail',
      (tester) async {
        final email = testEmail(
          listUnsubscribeHeader:
              '<mailto:unsub@example.com>, <https://example.com/unsubscribe>',
        );
        final repo = FakeEmailRepository(
          emailDetail: email,
          emailBody: const EmailBody(emailId: 'acc-1:42', attachments: []),
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ActionChip, 'Unsubscribe'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Send unsubscribe email'));
        await tester.pumpAndSettle();

        expect(repo.sentEmailDraft, isNotNull);
        expect(repo.sentEmailDraft!.to.first.email, 'unsub@example.com');
        expect(find.text('Unsubscribe email sent'), findsOneWidget);
      },
    );

    testWidgets('Show Mail Structure opens dialog with MIME parts', (
      tester,
    ) async {
      const body = EmailBody(
        emailId: 'acc-1:42',
        textBody: 'Hello',
        attachments: [],
        mimeTree: MimePart(
          contentType: 'multipart/mixed',
          children: [
            MimePart(contentType: 'text/plain', size: 100),
            MimePart(
              contentType: 'application/pdf',
              filename: 'report.pdf',
              size: 204800,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(body: body),
        ),
      );
      await tester.pumpAndSettle();

      // Open the popup menu.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      // Tap the structure item.
      await tester.tap(find.text('Show Mail Structure'));
      await tester.pumpAndSettle();

      // The dialog title and all three MIME parts must be visible.
      expect(find.text('Mail Structure'), findsOneWidget);
      expect(find.textContaining('multipart/mixed'), findsOneWidget);
      expect(find.textContaining('text/plain'), findsOneWidget);
      expect(find.textContaining('application/pdf'), findsOneWidget);
    });

    testWidgets(
      'Show Mail Structure auto-refetches body when mimeTree is absent',
      (tester) async {
        // Initially cached body has no mimeTree. A forced refetch returns a
        // body that does, so the dialog opens after the auto-refresh.
        const cachedBody = EmailBody(
          emailId: 'acc-1:42',
          textBody: 'Hello',
          attachments: [],
        );
        const refreshedBody = EmailBody(
          emailId: 'acc-1:42',
          textBody: 'Hello',
          attachments: [],
          mimeTree: MimePart(
            contentType: 'multipart/mixed',
            children: [
              MimePart(contentType: 'text/plain', size: 100),
            ],
          ),
        );
        final repo = FakeEmailRepository(
          emailDetail: testEmail(),
          emailBody: cachedBody,
          refreshedEmailBody: refreshedBody,
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Show Mail Structure'));
        await tester.pumpAndSettle();

        expect(repo.getEmailBodyForceRefreshCalls, 1);
        expect(find.text('Mail Structure'), findsOneWidget);
        expect(find.textContaining('multipart/mixed'), findsOneWidget);
        expect(find.textContaining('text/plain'), findsOneWidget);
      },
    );

    testWidgets(
      'Show Mail Structure shows snackbar when refetched body still lacks mimeTree',
      (tester) async {
        const body = EmailBody(
          emailId: 'acc-1:42',
          textBody: 'Hello',
          attachments: [],
        );
        final repo = FakeEmailRepository(
          emailDetail: testEmail(),
          emailBody: body,
          // refreshedEmailBody omitted -> forced refresh returns the same
          // mimeTree-less body, simulating a server that doesn't provide it.
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository()),
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Show Mail Structure'));
        await tester.pumpAndSettle();

        expect(repo.getEmailBodyForceRefreshCalls, 1);
        expect(
          find.textContaining(
            'Server did not return MIME structure for this message.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Load remote images snack bar auto-dismisses after 3 seconds',
      (tester) async {
        const body = EmailBody(
          emailId: 'acc-1:42',
          htmlBody: '<p>Hello <img src="https://example.com/x.png"/></p>',
          attachments: [],
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(body: body),
          ),
        );
        await tester.pumpAndSettle();

        // The "Load remote images" button is visible because the sender is
        // not yet trusted.
        expect(find.text('Load remote images'), findsOneWidget);

        await tester.tap(find.text('Load remote images'));
        // Settle the snack bar enter animation and the setState rebuild
        // that swaps in the image-loading WebView.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // Snack bar must be visible.
        expect(
          find.text('Images will be loaded automatically for this sender.'),
          findsOneWidget,
        );

        // After 3 seconds (the snack bar's duration) plus the reverse
        // animation, the snack bar must be gone.
        // Regression test for #484: SnackBar with an action defaults to
        // persist=true, which disables auto-dismiss — explicit persist:false
        // restores duration-based dismissal.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();

        expect(
          find.text('Images will be loaded automatically for this sender.'),
          findsNothing,
        );
      },
    );
  });
}

/// Email repository whose [getEmail] and [getEmailBody] futures never resolve,
/// used to test the loading state.
class _NeverEmailRepository extends FakeEmailRepository {
  _NeverEmailRepository() : super();

  @override
  Future<Email?> getEmail(String emailId) => Completer<Email?>().future;

  @override
  Future<EmailBody> getEmailBody(String emailId, {bool forceRefresh = false}) =>
      Completer<EmailBody>().future;
}
