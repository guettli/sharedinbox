// Generates Play Store promotional screenshots for all three device classes.
//
// Run with:
//   fvm flutter test test/screenshot_automation_test.dart --update-goldens
//
// Output: screenshots/{phone,tablet_7in,tablet_10in}/{light,dark}/<scene>.png
// at the repository root (one directory above test/).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';

import 'widget/helpers.dart';

// ---------------------------------------------------------------------------
// Device configurations
// ---------------------------------------------------------------------------

typedef _Device = ({String name, double width, double height});

const _devices = <_Device>[
  (name: 'phone', width: 1080.0, height: 1920.0),
  (name: 'tablet_7in', width: 1200.0, height: 1920.0),
  (name: 'tablet_10in', width: 1600.0, height: 2560.0),
];

// ---------------------------------------------------------------------------
// Sample data — fixed date so golden files are stable between runs
// ---------------------------------------------------------------------------

const _kAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@sharedinbox.de',
  imapHost: 'imap.sharedinbox.de',
  smtpHost: 'smtp.sharedinbox.de',
);

final _kDate = DateTime(2025, 5, 14, 10, 30);

Email _email({
  required String id,
  required String subject,
  required String fromName,
  required String fromEmail,
  bool isSeen = true,
  bool isFlagged = false,
  bool hasAttachment = false,
  String? preview,
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: 'INBOX',
      uid: int.parse(id.split(':').last),
      subject: subject,
      receivedAt: _kDate,
      sentAt: _kDate,
      from: [EmailAddress(name: fromName, email: fromEmail)],
      to: const [EmailAddress(name: 'Alice', email: 'alice@sharedinbox.de')],
      cc: const [],
      isSeen: isSeen,
      isFlagged: isFlagged,
      hasAttachment: hasAttachment,
      preview: preview,
    );

final _sampleEmails = [
  _email(
    id: 'acc-1:1',
    subject: 'Re: Project kick-off next week',
    fromName: 'Maria Hoffmann',
    fromEmail: 'maria@corp.example',
    isSeen: false,
    preview: 'Sounds great! I will prepare the slides beforehand.',
  ),
  _email(
    id: 'acc-1:2',
    subject: 'Your invoice #2024-0312 is ready',
    fromName: 'Billing',
    fromEmail: 'billing@service.example',
    isSeen: false,
    preview: 'Your invoice for May is attached as a PDF.',
  ),
  _email(
    id: 'acc-1:3',
    subject: 'Team lunch — Friday 12:30',
    fromName: 'Thomas Müller',
    fromEmail: 'thomas@corp.example',
    isFlagged: true,
    preview: 'The Italian place on Main Street. RSVP by Thursday please.',
  ),
  _email(
    id: 'acc-1:4',
    subject: 'Quarterly review agenda',
    fromName: 'HR Team',
    fromEmail: 'hr@corp.example',
    preview:
        "Please find the agenda for next week's quarterly review attached.",
  ),
  _email(
    id: 'acc-1:5',
    subject: 'Weekend hiking trip — photos inside',
    fromName: 'Jonas Weber',
    fromEmail: 'jonas@personal.example',
    hasAttachment: true,
    preview: 'Had such a great time! Here are the photos from Saturday.',
  ),
  _email(
    id: 'acc-1:6',
    subject: 'Reminder: dentist appointment tomorrow',
    fromName: 'City Dental',
    fromEmail: 'noreply@citydental.example',
    preview: 'Your appointment is confirmed for Thursday at 14:00.',
  ),
  _email(
    id: 'acc-1:7',
    subject: 'Re: Feedback on the draft',
    fromName: 'Laura Schmidt',
    fromEmail: 'laura@corp.example',
    isSeen: false,
    preview: 'I left some comments on page 3. Overall it looks really solid!',
  ),
  _email(
    id: 'acc-1:8',
    subject: 'Flight confirmation PNR XYZ123',
    fromName: 'Sunshine Airlines',
    fromEmail: 'noreply@airline.example',
    preview:
        'Your booking is confirmed. Check-in opens 24 hours before departure.',
  ),
];

final _sampleMailboxes = [
  const Mailbox(
    id: 'acc-1:INBOX',
    accountId: 'acc-1',
    path: 'INBOX',
    name: 'INBOX',
    role: 'inbox',
    unreadCount: 3,
    totalCount: 8,
  ),
  const Mailbox(
    id: 'acc-1:Sent',
    accountId: 'acc-1',
    path: 'Sent',
    name: 'Sent',
    role: 'sent',
    unreadCount: 0,
    totalCount: 42,
  ),
  const Mailbox(
    id: 'acc-1:Drafts',
    accountId: 'acc-1',
    path: 'Drafts',
    name: 'Drafts',
    role: 'drafts',
    unreadCount: 0,
    totalCount: 1,
  ),
  const Mailbox(
    id: 'acc-1:Trash',
    accountId: 'acc-1',
    path: 'Trash',
    name: 'Trash',
    role: 'trash',
    unreadCount: 0,
    totalCount: 7,
  ),
];

// Email shown in the detail scene.
final _detailEmail = _email(
  id: 'acc-1:1',
  subject: 'Re: Project kick-off next week',
  fromName: 'Maria Hoffmann',
  fromEmail: 'maria@corp.example',
);

const _detailBody = EmailBody(
  emailId: 'acc-1:1',
  attachments: [],
  textBody: 'Hi Alice,\n\n'
      'Sounds great! I will prepare the slides beforehand so we have '
      'something concrete to discuss.\n\n'
      'Looking forward to meeting everyone!\n\n'
      'Best,\nMaria',
);

// Emails shown when the user searches for "invoice".
final _searchResults = [
  _email(
    id: 'acc-1:2',
    subject: 'Your invoice #2024-0312 is ready',
    fromName: 'Billing',
    fromEmail: 'billing@service.example',
    isSeen: false,
  ),
  _email(
    id: 'acc-1:9',
    subject: 'Invoice for March services',
    fromName: 'Cloud Services',
    fromEmail: 'noreply@cloud.example',
  ),
];

// ---------------------------------------------------------------------------
// Provider override sets for each scene
// ---------------------------------------------------------------------------

List<Override> _inboxOverrides() => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([_kAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository(_sampleMailboxes),
      ),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(emails: _sampleEmails),
      ),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      searchHistoryRepositoryProvider.overrideWithValue(
        FakeSearchHistoryRepository(),
      ),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(null)),
    ];

List<Override> _detailOverrides() => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([_kAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository(_sampleMailboxes),
      ),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(
          emails: _sampleEmails,
          emailDetail: _detailEmail,
          emailBody: _detailBody,
        ),
      ),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(null)),
    ];

List<Override> _composeOverrides() => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([_kAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository(_sampleMailboxes),
      ),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(emails: _sampleEmails),
      ),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      searchHistoryRepositoryProvider.overrideWithValue(
        FakeSearchHistoryRepository(),
      ),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(null)),
    ];

List<Override> _mailboxOverrides() => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([_kAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository(_sampleMailboxes),
      ),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(null)),
    ];

List<Override> _searchOverrides() => [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([_kAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository(_sampleMailboxes),
      ),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(
          emails: _sampleEmails,
          searchResults: _searchResults,
        ),
      ),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      searchHistoryRepositoryProvider.overrideWithValue(
        FakeSearchHistoryRepository(),
      ),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(null)),
    ];

// ---------------------------------------------------------------------------
// Tests — 3 devices × 2 themes × 5 scenes = 30 golden files
// ---------------------------------------------------------------------------

void main() {
  for (final device in _devices) {
    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final themeName = themeMode == ThemeMode.light ? 'light' : 'dark';
      // Golden files are stored relative to this test file (test/).
      // The ../  prefix places them at repo root under screenshots/.
      final dir = '../screenshots/${device.name}/$themeName';

      group('${device.name}/$themeName', () {
        void setDevice(WidgetTester tester) {
          tester.view.physicalSize = Size(device.width, device.height);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
        }

        testWidgets('inbox_list', (tester) async {
          setDevice(tester);
          await tester.pumpWidget(
            buildApp(
              initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
              overrides: _inboxOverrides(),
              themeMode: themeMode,
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$dir/inbox_list.png'),
          );
        });

        testWidgets('email_detail', (tester) async {
          setDevice(tester);
          await tester.pumpWidget(
            buildApp(
              // The colon in "acc-1:1" must be percent-encoded in the URL.
              initialLocation:
                  '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A1',
              overrides: _detailOverrides(),
              themeMode: themeMode,
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$dir/email_detail.png'),
          );
        });

        testWidgets('compose', (tester) async {
          setDevice(tester);
          // Start at the inbox, then navigate to compose with pre-fill extras
          // so GoRouter can pass them to ComposeScreen via state.extra.
          await tester.pumpWidget(
            buildApp(
              initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
              overrides: _composeOverrides(),
              themeMode: themeMode,
            ),
          );
          await tester.pumpAndSettle();
          GoRouter.of(tester.element(find.byType(EmailListScreen))).go(
            '/compose',
            extra: <String, dynamic>{
              'accountId': 'acc-1',
              'prefillTo': 'thomas@corp.example',
              'prefillSubject': 'Re: Team lunch — Friday 12:30',
              'prefillBody':
                  'Hi Thomas,\n\nCount me in! See you on Friday.\n\nBest,\nAlice',
            },
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$dir/compose.png'),
          );
        });

        testWidgets('mailbox_list', (tester) async {
          setDevice(tester);
          await tester.pumpWidget(
            buildApp(
              initialLocation: '/accounts/acc-1/mailboxes',
              overrides: _mailboxOverrides(),
              themeMode: themeMode,
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$dir/mailbox_list.png'),
          );
        });

        testWidgets('search_results', (tester) async {
          setDevice(tester);
          await tester.pumpWidget(
            buildApp(
              initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
              overrides: _searchOverrides(),
              themeMode: themeMode,
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(SearchBar), 'invoice');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$dir/search_results.png'),
          );
        });
      });
    }
  }
}
