import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';

import 'helpers.dart';

/// A localhost IMAP account — the only shape where the SSL/TLS switches show.
/// `imapSsl` defaults to true, which is the state accounts saved before #936
/// was fixed are stuck in.
const _kLocalhostAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'localhost',
  imapPort: 1430,
  smtpHost: 'smtp.example.com',
  signature: 'Cheers,\nAlice',
);

/// The edit form does not fit the default test viewport.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Pumps the edit screen for [account] and waits for `_load()` to settle.
Future<void> _pumpEditAccount(
  WidgetTester tester, {
  Account account = kTestAccount,
  FakeAccountRepository? accountRepository,
  bool hasStoredPassword = true,
  Exception? connectionError,
}) async {
  _useTallViewport(tester);

  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/edit',
      overrides: baseOverrides(
        accounts: [account],
        accountRepository: accountRepository,
        hasStoredPassword: hasStoredPassword,
        connectionError: connectionError,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The IMAP/SMTP SSL switches, which share the title the sections scope.
Finder _sslSwitches() => find.widgetWithText(SwitchListTile, 'SSL/TLS');

void main() {
  group('EditAccountScreen', () {
    testWidgets('shows account email and type label after loading', (
      tester,
    ) async {
      await _pumpEditAccount(tester);

      expect(find.text('alice@example.com'), findsOneWidget);
      // "IMAP" appears as both the type badge and the IMAP section header.
      expect(find.text('IMAP'), findsWidgets);
    });

    testWidgets('pre-fills display name field', (tester) async {
      await _pumpEditAccount(tester);

      expect(find.widgetWithText(TextFormField, 'Alice'), findsOneWidget);
    });

    testWidgets('pre-fills the signature field', (tester) async {
      await _pumpEditAccount(tester, account: kSignedAccount);

      expect(find.byKey(const Key('editSignatureField')), findsOneWidget);
      final field = tester.widget<TextFormField>(
        find.byKey(const Key('editSignatureField')),
      );
      expect(field.controller!.text, 'Cheers,\nAlice');
    });

    testWidgets('shows Save button', (tester) async {
      await _pumpEditAccount(tester);

      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('does not show Force full sync button', (tester) async {
      await _pumpEditAccount(tester);

      expect(find.text('Force full sync'), findsNothing);
    });

    testWidgets('saving without password change pops back', (tester) async {
      await _pumpEditAccount(tester);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // After saving we pop back to the accounts list.
      expect(find.text('No accounts yet.'), findsNothing);
    });

    testWidgets('saving with new password runs connection test', (
      tester,
    ) async {
      await _pumpEditAccount(tester);

      await tester.enterText(
        find.byKey(const Key('editPasswordField')),
        'newsecret',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Successful save navigates back — edit screen title is gone.
      expect(find.text('Edit account'), findsNothing);
    });

    testWidgets(
      'try connection button is disabled when no password stored or entered',
      (tester) async {
        await _pumpEditAccount(tester, hasStoredPassword: false);

        final button = tester.widget<OutlinedButton>(
          find.byKey(const Key('editTryConnectionButton')),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'try connection button is enabled after typing password with no stored password',
      (tester) async {
        await _pumpEditAccount(tester, hasStoredPassword: false);

        await tester.enterText(
          find.byKey(const Key('editPasswordField')),
          'mypassword',
        );
        await tester.pump();

        final button = tester.widget<OutlinedButton>(
          find.byKey(const Key('editTryConnectionButton')),
        );
        expect(button.onPressed, isNotNull);
      },
    );

    testWidgets('save button is disabled when no password stored or entered', (
      tester,
    ) async {
      await _pumpEditAccount(tester, hasStoredPassword: false);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('connection error shows error message', (tester) async {
      await _pumpEditAccount(
        tester,
        connectionError: Exception('auth failed'),
      );

      await tester.enterText(
        find.byKey(const Key('editPasswordField')),
        'wrongpassword',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Save failed'), findsOneWidget);
    });

    testWidgets('no IMAP SSL switch for a non-localhost host', (tester) async {
      // kTestAccount's hosts are both remote, where implicit TLS is forced.
      await _pumpEditAccount(tester);

      expect(_sslSwitches(), findsNothing);
    });

    testWidgets(
        'IMAP SSL switch shows for localhost and reflects the stored '
        'value', (tester) async {
      await _pumpEditAccount(tester, account: _kLocalhostAccount);

      // Only the IMAP host is localhost, so this is the IMAP switch.
      expect(_sslSwitches(), findsOneWidget);
      expect(tester.widget<SwitchListTile>(_sslSwitches()).value, isTrue);
    });

    testWidgets('turning the IMAP SSL switch off is persisted', (tester) async {
      final repo = FakeAccountRepository([_kLocalhostAccount]);
      await _pumpEditAccount(
        tester,
        account: _kLocalhostAccount,
        accountRepository: repo,
      );

      await tester.tap(_sslSwitches());
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(_sslSwitches()).value, isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.accounts.single.imapSsl, isFalse);
    });

    testWidgets(
      'turning the IMAP SSL switch off survives the username-filling save',
      (tester) async {
        // Entering a password runs the connection test, which used to rebuild
        // the account field by field to fill in the username — dropping both
        // imapSsl and signature on the way (#936).
        final repo = FakeAccountRepository([_kLocalhostAccount]);
        await _pumpEditAccount(
          tester,
          account: _kLocalhostAccount,
          accountRepository: repo,
        );

        await tester.tap(_sslSwitches());
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('editPasswordField')),
          'newsecret',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final saved = repo.accounts.single;
        expect(saved.imapSsl, isFalse);
        expect(saved.signature, 'Cheers,\nAlice');
        // The one thing the rebuild was there for.
        expect(saved.username, 'alice@example.com');
      },
    );
  });
}
