import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('EmailDetailScreen', () {
    testWidgets('shows loading spinner before data arrives', (tester) async {
      // Use a Completer-backed repo so data never arrives during this test.
      final neverRepo = _NeverEmailRepository();
      await tester.pumpWidget(buildApp(
        initialLocation:
            '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider.overrideWithValue(neverRepo),
        ],
      ));
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
      await tester.pumpWidget(buildApp(
        initialLocation:
            '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider.overrideWithValue(
            FakeEmailRepository(emailDetail: email, emailBody: body),
          ),
        ],
      ));
      await tester.pumpAndSettle();

      // Subject appears in both the app bar and the email header section.
      expect(find.text('Project update'), findsAtLeastNWidgets(1));
      expect(find.text('See attached slides.'), findsOneWidget);
    });

    testWidgets('shows from-address in header', (tester) async {
      final email = testEmail();
      const body =
          EmailBody(emailId: 'acc-1:42', textBody: 'Hi', attachments: []);
      await tester.pumpWidget(buildApp(
        initialLocation:
            '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider.overrideWithValue(
            FakeEmailRepository(emailDetail: email, emailBody: body),
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('bob@example.com'), findsOneWidget);
    });

    testWidgets('shows attachment section when email has attachments',
        (tester) async {
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
      await tester.pumpWidget(buildApp(
        initialLocation:
            '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider.overrideWithValue(
            FakeEmailRepository(emailDetail: email, emailBody: body),
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Attachments'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    });
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
