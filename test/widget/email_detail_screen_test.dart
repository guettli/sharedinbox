import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/platform/raw_email_downloader.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';

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

    testWidgets(
      'shows a partial-decode notice with a raw-source link and keeps the '
      'action bar (#579)',
      (tester) async {
        // A body that only partially decoded (malformed MIME) — the screen
        // must still open, show a notice + "View raw source", and keep its
        // actions usable rather than dying with a raw RangeError.
        const body = EmailBody(
          emailId: 'acc-1:42',
          textBody: 'partial text that did decode',
          attachments: [],
          decodeFailed: true,
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
            overrides: _overrides(body: body),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('This message could not be fully displayed.'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextButton, 'View raw source'),
          findsOneWidget,
        );
        // Whatever decoded is still shown …
        expect(find.text('partial text that did decode'), findsOneWidget);
        // … and the action bar is intact (e.g. the Archive button).
        expect(
          find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Archive'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows a SnackBar pointing at the app log when the body fails to load '
      '(#587)',
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
              emailRepositoryProvider
                  .overrideWithValue(_FailingEmailRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // The in-body error panel is shown …
        expect(find.text('This message could not be opened.'), findsOneWidget);
        // … alongside a SnackBar that hints at the app log with a "Show logs"
        // action.
        expect(
          find.text('Could not load this message. See the app log for '
              'details.'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(SnackBarAction, 'Show logs'),
          findsOneWidget,
        );

        // A plain rebuild must not re-show the SnackBar. Let the current one
        // fade, then pump again without changing provider state.
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(
          find.text('Could not load this message. See the app log for '
              'details.'),
          findsNothing,
        );

        // Re-render the screen — no state transition into error, so no snack.
        await tester.pump();
        expect(
          find.text('Could not load this message. See the app log for '
              'details.'),
          findsNothing,
        );
      },
    );

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

    testWidgets(
      'Mark as spam navigates to the next INBOX message, not a Junk one (#293)',
      (tester) async {
        // Three emails on the account: two live in INBOX, one lives in Junk.
        // The dates are picked so an unfiltered "next" lookup would pick the
        // Junk mail (its date sits between the two INBOX mails), which is
        // exactly the scenario from #293.
        final inbox1 = Email(
          id: 'acc-1:1',
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          uid: 1,
          subject: 'Inbox mail one',
          receivedAt: DateTime(2024, 6, 3),
          sentAt: DateTime(2024, 6, 3),
          from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        final junkMail = Email(
          id: 'acc-1:99',
          accountId: 'acc-1',
          mailboxPath: 'Junk',
          uid: 99,
          subject: 'Junk mail from junk folder',
          receivedAt: DateTime(2024, 6, 2),
          sentAt: DateTime(2024, 6, 2),
          from: const [
            EmailAddress(name: 'Spam', email: 'spam@example.com'),
          ],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        final inbox2 = Email(
          id: 'acc-1:2',
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          uid: 2,
          subject: 'Inbox mail two',
          receivedAt: DateTime(2024, 6),
          sentAt: DateTime(2024, 6),
          from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );

        const mailboxes = [
          Mailbox(
            id: 'acc-1:INBOX',
            accountId: 'acc-1',
            path: 'INBOX',
            name: 'INBOX',
            role: 'inbox',
            unreadCount: 2,
            totalCount: 2,
          ),
          Mailbox(
            id: 'acc-1:Junk',
            accountId: 'acc-1',
            path: 'Junk',
            name: 'Junk',
            role: 'junk',
            unreadCount: 1,
            totalCount: 1,
          ),
        ];

        const body = EmailBody(emailId: 'acc-1:1', attachments: []);

        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository(mailboxes)),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  emails: [inbox1, junkMail, inbox2],
                  emailBody: body,
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Precondition: we opened the first INBOX mail.
        expect(find.text('Inbox mail one'), findsOneWidget);

        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Mark as spam',
          ),
        );
        await tester.pumpAndSettle();

        // After marking as spam we must land on the next INBOX message, not
        // on the junk-folder mail whose date sits between the two INBOX
        // ones. The subject of the junk mail must never appear.
        expect(find.text('Junk mail from junk folder'), findsNothing);
        expect(find.text('Inbox mail two'), findsOneWidget);
      },
    );

    testWidgets(
      'Junk folder replaces "Mark as spam" with "Not junk" (#621)',
      (tester) async {
        final junkMail = Email(
          id: 'acc-1:99',
          accountId: 'acc-1',
          mailboxPath: 'Junk',
          uid: 99,
          subject: 'Not actually junk',
          receivedAt: DateTime(2024, 6),
          sentAt: DateTime(2024, 6),
          from: const [EmailAddress(email: 'bob@example.com')],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        const mailboxes = [
          Mailbox(
            id: 'acc-1:Junk',
            accountId: 'acc-1',
            path: 'Junk',
            name: 'Junk',
            role: 'junk',
            unreadCount: 1,
            totalCount: 1,
          ),
        ];

        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes/Junk/emails/acc-1%3A99',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository(mailboxes)),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  emailDetail: junkMail,
                  emailBody:
                      const EmailBody(emailId: 'acc-1:99', attachments: []),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Not junk',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Mark as spam',
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Trash folder replaces "Delete" with "Restore" (#621)',
      (tester) async {
        final trashMail = Email(
          id: 'acc-1:77',
          accountId: 'acc-1',
          mailboxPath: 'Trash',
          uid: 77,
          subject: 'Deleted by mistake',
          receivedAt: DateTime(2024, 6),
          sentAt: DateTime(2024, 6),
          from: const [EmailAddress(email: 'bob@example.com')],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        const mailboxes = [
          Mailbox(
            id: 'acc-1:Trash',
            accountId: 'acc-1',
            path: 'Trash',
            name: 'Trash',
            role: 'trash',
            unreadCount: 1,
            totalCount: 1,
          ),
        ];

        await tester.pumpWidget(
          buildApp(
            initialLocation:
                '/accounts/acc-1/mailboxes/Trash/emails/acc-1%3A77',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider
                  .overrideWithValue(FakeMailboxRepository(mailboxes)),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  emailDetail: trashMail,
                  emailBody:
                      const EmailBody(emailId: 'acc-1:77', attachments: []),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Restore',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'Delete',
          ),
          findsNothing,
        );
      },
    );

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

    testWidgets('Select text opens a dialog with the stripped body text', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(
              emailId: 'acc-1:42',
              htmlBody: '<p>Hello selectable world</p>',
              attachments: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Select text'), findsOneWidget);
      await tester.tap(find.text('Select text'));
      await tester.pumpAndSettle();

      // The dialog shows the HTML stripped to plain text inside a
      // SelectableText the user can highlight and copy.
      final selectable = find.byType(SelectableText);
      expect(selectable, findsOneWidget);
      expect(
        tester.widget<SelectableText>(selectable).data,
        'Hello selectable world',
      );
      expect(find.text('Copy all'), findsOneWidget);
    });

    testWidgets('Select text copies the body to the clipboard', (tester) async {
      final clipboardTexts = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardTexts.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: _overrides(
            body: const EmailBody(
              emailId: 'acc-1:42',
              textBody: 'Plain body to copy',
              attachments: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select text'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy all'));
      await tester.pumpAndSettle();

      expect(clipboardTexts, ['Plain body to copy']);
      expect(find.text('Copied to clipboard'), findsOneWidget);
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

    group('Prev/Next navigation (#292)', () {
      // The chevron controls are only shown on desktop platforms. Widget
      // tests default to TargetPlatform.android, so each test switches
      // to a desktop platform for the duration of its body.  The reset
      // has to happen INSIDE the test body — Flutter's post-test
      // invariants check runs before setUp/tearDown callbacks fire, so a
      // group-level tearDown would trigger "foundation debug variable was
      // changed by the test" (issue #292).
      Future<void> withDesktopPlatform(
        Future<void> Function() body,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          await body();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      Email navMail(String id, {String mailbox = 'INBOX'}) => Email(
            id: id,
            accountId: 'acc-1',
            mailboxPath: mailbox,
            uid: int.parse(id.split(':').last),
            subject: 'Mail $id',
            receivedAt: DateTime(2024, 6),
            sentAt: DateTime(2024, 6),
            from: const [
              EmailAddress(name: 'Bob', email: 'bob@example.com'),
            ],
            to: const [EmailAddress(email: 'alice@example.com')],
            cc: const [],
            isSeen: false,
            isFlagged: false,
            hasAttachment: false,
          );

      testWidgets(
        'shows enabled prev+next chevrons in the middle of nav',
        (tester) => withDesktopPlatform(() async {
          final nav = EmailDetailNav.fromEmails([
            navMail('acc-1:1'),
            navMail('acc-1:2'),
            navMail('acc-1:3'),
          ]);

          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A2',
              initialExtra: nav,
              overrides: _overrides(
                body: const EmailBody(emailId: 'acc-1:2', attachments: []),
                email: navMail('acc-1:2'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final prev = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.chevron_left),
              matching: find.byType(IconButton),
            ),
          );
          final next = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.chevron_right),
              matching: find.byType(IconButton),
            ),
          );
          expect(prev.onPressed, isNotNull);
          expect(next.onPressed, isNotNull);
        }),
      );

      testWidgets(
        'disables prev at first message',
        (tester) => withDesktopPlatform(() async {
          final nav = EmailDetailNav.fromEmails([
            navMail('acc-1:1'),
            navMail('acc-1:2'),
          ]);
          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
              initialExtra: nav,
              overrides: _overrides(
                body: const EmailBody(emailId: 'acc-1:1', attachments: []),
                email: navMail('acc-1:1'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final prev = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.chevron_left),
              matching: find.byType(IconButton),
            ),
          );
          expect(prev.onPressed, isNull);
        }),
      );

      testWidgets(
        'disables next at last message',
        (tester) => withDesktopPlatform(() async {
          final nav = EmailDetailNav.fromEmails([
            navMail('acc-1:1'),
            navMail('acc-1:2'),
          ]);
          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A2',
              initialExtra: nav,
              overrides: _overrides(
                body: const EmailBody(emailId: 'acc-1:2', attachments: []),
                email: navMail('acc-1:2'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final next = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.chevron_right),
              matching: find.byType(IconButton),
            ),
          );
          expect(next.onPressed, isNull);
        }),
      );

      testWidgets(
        'tapping next navigates to the next email in nav',
        (tester) => withDesktopPlatform(() async {
          final second = navMail('acc-1:2');
          final nav = EmailDetailNav.fromEmails([navMail('acc-1:1'), second]);
          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
              initialExtra: nav,
              overrides: [
                accountRepositoryProvider.overrideWithValue(
                  FakeAccountRepository([kTestAccount]),
                ),
                mailboxRepositoryProvider
                    .overrideWithValue(FakeMailboxRepository()),
                emailRepositoryProvider.overrideWithValue(
                  FakeEmailRepository(
                    // Both emails are resolvable so the detail screen renders
                    // after the route hop.
                    emails: [navMail('acc-1:1'), second],
                    emailBody:
                        const EmailBody(emailId: 'acc-1:1', attachments: []),
                  ),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Mail acc-1:1'), findsOneWidget);

          await tester.tap(find.byIcon(Icons.chevron_right));
          await tester.pumpAndSettle();

          // Route swapped to the neighbour; its subject is now on screen.
          expect(find.text('Mail acc-1:2'), findsOneWidget);
          expect(find.text('Mail acc-1:1'), findsNothing);
        }),
      );

      testWidgets(
        'falls back to the mailbox stream when nav is not supplied',
        (tester) => withDesktopPlatform(() async {
          final one = navMail('acc-1:1');
          final two = navMail('acc-1:2');
          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
              overrides: [
                accountRepositoryProvider.overrideWithValue(
                  FakeAccountRepository([kTestAccount]),
                ),
                mailboxRepositoryProvider
                    .overrideWithValue(FakeMailboxRepository()),
                emailRepositoryProvider.overrideWithValue(
                  FakeEmailRepository(
                    emails: [one, two],
                    emailBody:
                        const EmailBody(emailId: 'acc-1:1', attachments: []),
                  ),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();

          final next = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.chevron_right),
              matching: find.byType(IconButton),
            ),
          );
          expect(next.onPressed, isNotNull);
        }),
      );
    });

    group('Swipe navigation (#292)', () {
      testWidgets(
        'left-swipe on mobile navigates to the next email',
        (tester) async {
          Email mail(String id) => Email(
                id: id,
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: int.parse(id.split(':').last),
                subject: 'Mail $id',
                receivedAt: DateTime(2024, 6),
                sentAt: DateTime(2024, 6),
                from: const [
                  EmailAddress(name: 'Bob', email: 'bob@example.com'),
                ],
                to: const [EmailAddress(email: 'alice@example.com')],
                cc: const [],
                isSeen: false,
                isFlagged: false,
                hasAttachment: false,
              );

          final nav =
              EmailDetailNav.fromEmails([mail('acc-1:1'), mail('acc-1:2')]);
          await tester.pumpWidget(
            buildApp(
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
              initialExtra: nav,
              overrides: [
                accountRepositoryProvider.overrideWithValue(
                  FakeAccountRepository([kTestAccount]),
                ),
                mailboxRepositoryProvider
                    .overrideWithValue(FakeMailboxRepository()),
                emailRepositoryProvider.overrideWithValue(
                  FakeEmailRepository(
                    emails: [mail('acc-1:1'), mail('acc-1:2')],
                    emailBody:
                        const EmailBody(emailId: 'acc-1:1', attachments: []),
                  ),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Mail acc-1:1'), findsOneWidget);

          // Fling left with enough velocity to trip the 300 px/s threshold.
          await tester.fling(
            find.byType(Scaffold),
            const Offset(-400, 0),
            1000,
          );
          await tester.pumpAndSettle();

          expect(find.text('Mail acc-1:2'), findsOneWidget);
          expect(find.text('Mail acc-1:1'), findsNothing);
        },
      );
    });

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

/// Email repository whose [getEmailBody] always throws, used to drive the
/// detail provider into its error state (#587).
class _FailingEmailRepository extends FakeEmailRepository {
  _FailingEmailRepository() : super();

  @override
  Future<EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
  }) async =>
      throw StateError('boom');
}
