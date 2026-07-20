import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('CombinedInboxScreen', () {
    testWidgets(
      'overflow menu exposes "Debug messages" entry in selection mode (#345)',
      (tester) async {
        final email = testEmail(subject: 'Merged inbox mail');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/inbox',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(emails: [email]),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Merged inbox mail'), findsOneWidget);

        // Enter selection mode: same long-press affordance as every other list.
        await tester.longPress(find.text('Merged inbox mail'));
        await tester.pumpAndSettle();

        // Selection AppBar swaps in and the "..." overflow is present.
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.byIcon(Icons.select_all), findsOneWidget);
        expect(find.byTooltip('More actions'), findsOneWidget);

        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();

        expect(find.text('Debug messages'), findsOneWidget);
      },
    );
  });
}
