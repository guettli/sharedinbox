import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/discovery_result.dart';

import 'helpers.dart';

void main() {
  group('AddAccountScreen', () {
    testWidgets('step 1: shows email field and Continue button',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add account'), findsOneWidget);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('step 1: empty submit shows validation error', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('step 1: invalid email shows validation error', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('emailField')), 'notanemail');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('unknown discovery shows choose-type step', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(discovery: UnknownDiscovery()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('JMAP'), findsOneWidget);
      expect(find.text('IMAP / SMTP'), findsOneWidget);
    });

    testWidgets('JMAP discovery navigates directly to JMAP form',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(
            discovery:
                JmapDiscovery(sessionUrl: 'https://mail.example.com/jmap'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('JMAP API URL'), findsOneWidget);
      expect(find.text('https://mail.example.com/jmap'), findsOneWidget);
    });

    testWidgets('IMAP discovery navigates directly to IMAP form',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(
            discovery: ImapSmtpDiscovery(
              imapHost: 'imap.example.com',
              imapPort: 993,
              imapSsl: true,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              smtpSsl: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('IMAP / SMTP'), findsWidgets);
      expect(find.text('imap.example.com'), findsOneWidget);
      expect(find.text('smtp.example.com'), findsOneWidget);
    });

    testWidgets('choose-type: tapping JMAP shows JMAP form', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(discovery: UnknownDiscovery()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('JMAP'));
      await tester.pumpAndSettle();

      expect(find.text('JMAP API URL'), findsOneWidget);
    });

    testWidgets('choose-type: tapping IMAP/SMTP shows IMAP form',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(discovery: UnknownDiscovery()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('IMAP / SMTP'));
      await tester.pumpAndSettle();

      expect(find.text('IMAP'), findsOneWidget);
      expect(find.text('SMTP'), findsOneWidget);
    });

    testWidgets('successful JMAP save pops back to accounts list',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(
            discovery:
                JmapDiscovery(sessionUrl: 'https://mail.example.com/jmap'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Alice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'secret',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('No accounts yet.'), findsOneWidget);
    });

    testWidgets('JMAP connection failure shows error message', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(
            discovery:
                JmapDiscovery(sessionUrl: 'https://mail.example.com/jmap'),
            connectionError: Exception('auth failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Alice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'wrong',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection failed'), findsOneWidget);
    });

    testWidgets('successful IMAP save pops back to accounts list',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(
            discovery: ImapSmtpDiscovery(
              imapHost: 'imap.example.com',
              imapPort: 993,
              imapSsl: true,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              smtpSsl: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Alice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'secret',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('No accounts yet.'), findsOneWidget);
    });

    testWidgets('IMAP form shows SSL/TLS label and SMTP toggle',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/add',
          overrides: baseOverrides(discovery: UnknownDiscovery()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('emailField')),
        'user@example.com',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('IMAP / SMTP'));
      await tester.pumpAndSettle();

      expect(find.text('IMAP'), findsOneWidget);
      // IMAP and SMTP each have an SSL/TLS toggle (the ManageSieve toggle is
      // hidden inside a collapsed ExpansionTile).
      expect(find.byType(SwitchListTile), findsNWidgets(2));
    });
  });
}
