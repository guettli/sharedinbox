import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';

import 'helpers.dart';

void main() {
  group('AccountExportScreen', () {
    const account = Account(
      id: 'acc-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: 'imap.example.com',
      smtpHost: 'smtp.example.com',
    );

    testWidgets('shows QR code and copy button after loading', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/export',
          overrides: baseOverrides(accounts: [account]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('accountQrCode')), findsOneWidget);
      expect(find.byKey(const Key('copyCodeButton')), findsOneWidget);
    });

    testWidgets('shows password warning', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/export',
          overrides: baseOverrides(accounts: [account]),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('password'),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('AccountImportScreen', () {
    testWidgets('shows instruction text and disabled import button', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/import',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Import account'), findsOneWidget);
      expect(find.byKey(const Key('importCodeField')), findsOneWidget);

      final importBtn = tester.widget<FilledButton>(
        find.byKey(const Key('importButton')),
      );
      expect(importBtn.onPressed, isNull);
    });

    testWidgets('invalid JSON shows error message', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/import',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('importCodeField')),
        'not valid json',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Invalid code'), findsOneWidget);
    });

    testWidgets('valid code shows account preview and enables import', (
      tester,
    ) async {
      const account = Account(
        id: 'acc-99',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      final code = jsonEncode({
        'v': 1,
        'account': account.toJson(),
        'password': 'secret',
      });

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/import',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('importCodeField')),
        code,
      );
      await tester.pumpAndSettle();

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('bob@example.com'), findsOneWidget);

      final importBtn = tester.widget<FilledButton>(
        find.byKey(const Key('importButton')),
      );
      expect(importBtn.onPressed, isNotNull);
    });

    testWidgets('successful import navigates back to accounts list', (
      tester,
    ) async {
      const account = Account(
        id: 'acc-99',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      final code = jsonEncode({
        'v': 1,
        'account': account.toJson(),
        'password': 'secret',
      });

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/import',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('importCodeField')),
        code,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('importButton')));
      await tester.pumpAndSettle();

      expect(find.text('SharedInbox'), findsOneWidget);
    });
  });
}
