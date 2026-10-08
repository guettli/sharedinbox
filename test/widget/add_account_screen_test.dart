import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/discovery_result.dart';

import 'helpers.dart';

/// The discovery fixtures the tests below hand to [baseOverrides].
JmapDiscovery _jmapDiscovery() =>
    JmapDiscovery(sessionUrl: 'https://mail.example.com/jmap');

ImapSmtpDiscovery _imapDiscovery() => ImapSmtpDiscovery(
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSsl: true,
      smtpHost: 'smtp.example.com',
      smtpPort: 587,
      smtpSsl: false,
    );

/// Discovery pointing at a local server — the only shape whose SSL flags
/// survive `_buildImapAccount()`, and so the only one that can be asserted.
ImapSmtpDiscovery _localhostDiscovery() => ImapSmtpDiscovery(
      imapHost: 'localhost',
      imapPort: 1430,
      imapSsl: false,
      smtpHost: 'localhost',
      smtpPort: 1025,
      smtpSsl: false,
    );

/// Pumps the add-account screen at step 1 with [overrides] in place.
Future<void> _pumpAddAccount(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    buildApp(initialLocation: '/accounts/add', overrides: overrides),
  );
  await tester.pumpAndSettle();
}

/// Pumps the add-account screen, enters the email and advances past discovery.
Future<void> _submitEmail(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await _pumpAddAccount(tester, overrides: overrides);

  await tester.enterText(
    find.byKey(const Key('emailField')),
    'user@example.com',
  );
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

/// Fills the display name and password the JMAP and IMAP forms share.
Future<void> _fillCredentials(
  WidgetTester tester, {
  String password = 'secret',
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Display name'),
    'Alice',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    password,
  );
}

/// Drives discovery → credentials → Save and asserts the screen popped back to
/// the accounts list. Shared by the JMAP and IMAP happy paths, which differ
/// only in the [discovery] result they start from.
Future<void> _expectSavePopsToAccountList(
  WidgetTester tester, {
  required DiscoveryResult discovery,
}) async {
  await _submitEmail(tester, overrides: baseOverrides(discovery: discovery));

  await _fillCredentials(tester);
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();

  expect(find.text('Welcome to sharedinbox.de'), findsOneWidget);
}

/// The IMAP form does not fit the default test viewport.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('AddAccountScreen', () {
    testWidgets('step 1: shows Receive account button', (tester) async {
      await _pumpAddAccount(tester, overrides: baseOverrides());

      expect(find.byKey(const Key('importAccountButton')), findsOneWidget);
      expect(find.text('Receive account'), findsOneWidget);
    });

    testWidgets('step 1: shows email field and Continue button', (
      tester,
    ) async {
      await _pumpAddAccount(tester, overrides: baseOverrides());

      expect(find.text('Add account'), findsOneWidget);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('step 1: empty submit shows validation error', (tester) async {
      await _pumpAddAccount(tester, overrides: baseOverrides());

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('step 1: invalid email shows validation error', (tester) async {
      await _pumpAddAccount(tester, overrides: baseOverrides());

      await tester.enterText(find.byKey(const Key('emailField')), 'notanemail');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('unknown discovery shows choose-type step', (tester) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: UnknownDiscovery()),
      );

      expect(find.text('JMAP'), findsOneWidget);
      expect(find.text('IMAP / SMTP'), findsOneWidget);
    });

    testWidgets('JMAP discovery navigates directly to JMAP form', (
      tester,
    ) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _jmapDiscovery()),
      );

      expect(find.text('JMAP API URL'), findsOneWidget);
      expect(find.text('https://mail.example.com/jmap'), findsOneWidget);
    });

    testWidgets('IMAP discovery navigates directly to IMAP form', (
      tester,
    ) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _imapDiscovery()),
      );

      expect(find.text('IMAP / SMTP'), findsWidgets);
      expect(find.text('imap.example.com'), findsOneWidget);
      expect(find.text('smtp.example.com'), findsOneWidget);
    });

    // Regression for #979. Discovery committed the user to whichever protocol
    // it found: neither form offered a way to pick the other, and the chooser
    // was reachable only when detection failed. A server speaking both could
    // therefore only be added over the detected one.
    testWidgets('each form offers a switch to the other protocol',
        (tester) async {
      _useTallViewport(tester);

      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _jmapDiscovery()),
      );
      expect(find.text('JMAP API URL'), findsOneWidget);

      await tester.tap(find.byKey(const Key('switchToImapButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('switchToJmapButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('switchToJmapButton')));
      await tester.pumpAndSettle();
      expect(find.text('JMAP API URL'), findsOneWidget);
    });

    // Switching away and back must not destroy what auto-detection found:
    // nothing re-runs discovery, so the only recovery would be abandoning the
    // whole flow. smtpPort 587 is the load-bearing value here — it is the one
    // detected setting that differs from the form's own default of 465, so a
    // blind reset to defaults is visible and an assertion on 993 would not be.
    testWidgets('round trip keeps the detected IMAP settings', (tester) async {
      _useTallViewport(tester);

      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _imapDiscovery()),
      );
      expect(find.text('587'), findsOneWidget);

      await tester.tap(find.byKey(const Key('switchToJmapButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('switchToImapButton')));
      await tester.pumpAndSettle();

      expect(find.text('imap.example.com'), findsOneWidget);
      expect(find.text('smtp.example.com'), findsOneWidget);
      expect(find.text('587'), findsOneWidget);
      expect(find.text('465'), findsNothing);
    });

    testWidgets('round trip keeps the detected JMAP session URL',
        (tester) async {
      _useTallViewport(tester);

      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _jmapDiscovery()),
      );

      await tester.tap(find.byKey(const Key('switchToImapButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('switchToJmapButton')));
      await tester.pumpAndSettle();

      expect(find.text('https://mail.example.com/jmap'), findsOneWidget);
    });

    // The Try-connection banner renders from shared state on both forms, so a
    // result from the protocol just abandoned would otherwise sit above Save
    // claiming success for settings that are no longer on screen.
    testWidgets('switching clears a Try-connection result', (tester) async {
      _useTallViewport(tester);

      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _jmapDiscovery()),
      );
      await tester.enterText(find.byType(TextFormField).at(0), 'Display');
      await tester.enterText(find.byType(TextFormField).at(3), 'pw');
      await tester.tap(find.byKey(const Key('tryConnectionButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connected as'), findsOneWidget);

      await tester.tap(find.byKey(const Key('switchToImapButton')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connected as'), findsNothing);
    });

    testWidgets('IMAP discovery seeds both SSL switches', (tester) async {
      _useTallViewport(tester);

      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: _localhostDiscovery()),
      );

      // Both switches are shown (localhost hosts) and carry what discovery
      // reported, rather than the field defaults.
      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches.length, 2);
      for (final s in switches) {
        expect(s.value, isFalse);
      }
    });

    testWidgets('choose-type: tapping JMAP shows JMAP form', (tester) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: UnknownDiscovery()),
      );

      await tester.tap(find.text('JMAP'));
      await tester.pumpAndSettle();

      expect(find.text('JMAP API URL'), findsOneWidget);
    });

    testWidgets('choose-type: tapping IMAP/SMTP shows IMAP form', (
      tester,
    ) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(discovery: UnknownDiscovery()),
      );

      await tester.tap(find.text('IMAP / SMTP'));
      await tester.pumpAndSettle();

      expect(find.text('IMAP'), findsOneWidget);
      expect(find.text('SMTP'), findsOneWidget);
    });

    testWidgets('successful JMAP save pops back to accounts list', (
      tester,
    ) async {
      await _expectSavePopsToAccountList(tester, discovery: _jmapDiscovery());
    });

    testWidgets('JMAP connection failure shows error message', (tester) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(
          discovery: _jmapDiscovery(),
          connectionError: Exception('auth failed'),
        ),
      );

      await _fillCredentials(tester, password: 'wrong');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection failed'), findsOneWidget);
    });

    testWidgets('JMAP try connection surfaces identity warning', (
      tester,
    ) async {
      await _submitEmail(
        tester,
        overrides: baseOverrides(
          discovery: _jmapDiscovery(),
          connectionIdentityWarning:
              'No send identity on the server matches user@example.com.',
        ),
      );

      await _fillCredentials(tester);
      await tester.tap(find.text('Try connection'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No send identity on the server matches'),
        findsOneWidget,
      );
    });

    testWidgets('successful IMAP save pops back to accounts list', (
      tester,
    ) async {
      _useTallViewport(tester);

      await _expectSavePopsToAccountList(tester, discovery: _imapDiscovery());
    });

    testWidgets('IMAP save keeps the SSL switches off', (tester) async {
      _useTallViewport(tester);

      final repo = FakeAccountRepository();
      await _submitEmail(
        tester,
        overrides: baseOverrides(
          discovery: UnknownDiscovery(),
          accountRepository: repo,
        ),
      );

      await tester.tap(find.text('IMAP / SMTP'));
      await tester.pumpAndSettle();

      await _fillCredentials(tester);
      // localhost is what reveals the SSL switches at all.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host').first,
        'localhost',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Port').first,
        '1430',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host').last,
        'localhost',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Port').last,
        '1025',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.tap(find.byType(SwitchListTile).last);
      await tester.pumpAndSettle();
      for (final s in tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      )) {
        expect(s.value, isFalse);
      }

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = repo.accounts.single;
      expect(saved.imapSsl, isFalse);
      expect(saved.smtpSsl, isFalse);
      expect(saved.imapPort, 1430);
      expect(saved.smtpPort, 1025);
      // Filled in from the connection test -- the one thing the rebuilt
      // account was there for.
      expect(saved.username, 'user@example.com');
    });

    testWidgets(
      'IMAP form hides SSL toggle for non-localhost, shows for localhost',
      (tester) async {
        await _submitEmail(
          tester,
          overrides: baseOverrides(discovery: UnknownDiscovery()),
        );

        await tester.tap(find.text('IMAP / SMTP'));
        await tester.pumpAndSettle();

        expect(find.text('IMAP'), findsOneWidget);
        // No SSL toggles shown when hosts are empty (non-localhost).
        expect(find.byType(SwitchListTile), findsNothing);

        // Entering localhost as IMAP host reveals the IMAP SSL toggle.
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Host').first,
          'localhost',
        );
        await tester.pumpAndSettle();
        expect(find.byType(SwitchListTile), findsOneWidget);

        // Entering localhost as SMTP host reveals both SSL toggles.
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Host').last,
          'localhost',
        );
        await tester.pumpAndSettle();
        expect(find.byType(SwitchListTile), findsNWidgets(2));
      },
    );
  });
}
