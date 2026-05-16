import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:sharedinbox/core/models/email.dart';
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
        FakeEmailRepository(
          emailDetail: email ?? testEmail(),
          emailBody: body,
        ),
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

    testWidgets('shows subject in app bar after data loads', (tester) async {
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

      // Subject appears in both the app bar and the email header section.
      expect(find.text('Project update'), findsAtLeastNWidgets(1));
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
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: testEmail(),
                emailBody:
                    const EmailBody(emailId: 'acc-1:42', attachments: []),
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
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: testEmail(),
                emailBody:
                    const EmailBody(emailId: 'acc-1:42', attachments: []),
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
      // SnackBar with Share action must be visible.
      expect(find.text('Share'), findsOneWidget);
    });

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
      'Show Mail Structure shows snackbar when mimeTree is absent',
      (tester) async {
        const body = EmailBody(
          emailId: 'acc-1:42',
          textBody: 'Hello',
          attachments: [],
          // mimeTree is null — not yet cached or not available.
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(body: body),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Show Mail Structure'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Structure not available'),
          findsOneWidget,
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
  Future<EmailBody> getEmailBody(String emailId) =>
      Completer<EmailBody>().future;
}
