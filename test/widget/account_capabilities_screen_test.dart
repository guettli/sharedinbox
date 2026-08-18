import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/server_capabilities_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/account_capabilities_screen.dart';

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Future<void> _pump(
  WidgetTester tester, {
  required Future<ServerCapabilities> Function() capabilities,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountByIdProvider.overrideWith((ref, id) => Stream.value(_account)),
        serverCapabilitiesProvider.overrideWith((ref, id) => capabilities()),
      ],
      child: const MaterialApp(
        home: AccountCapabilitiesScreen(accountId: 'acc-1'),
      ),
    ),
  );
}

void main() {
  group('AccountCapabilitiesScreen', () {
    testWidgets('lists the capability tokens with a count', (tester) async {
      await _pump(
        tester,
        capabilities: () async => const ServerCapabilities(
          type: AccountType.imap,
          capabilities: ['IDLE', 'MOVE', 'UIDPLUS'],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('IDLE'), findsOneWidget);
      expect(find.text('MOVE'), findsOneWidget);
      expect(find.text('UIDPLUS'), findsOneWidget);
      expect(find.textContaining('IMAP · 3 capabilities'), findsOneWidget);
    });

    testWidgets('shows an empty-state message when none are advertised',
        (tester) async {
      await _pump(
        tester,
        capabilities: () async => const ServerCapabilities(
          type: AccountType.jmap,
          capabilities: [],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('did not advertise any capabilities'),
        findsOneWidget,
      );
    });

    testWidgets('shows an error view with a Retry button on failure',
        (tester) async {
      await _pump(
        tester,
        capabilities: () async => throw Exception('auth failed'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not reach the server'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });
  });
}
