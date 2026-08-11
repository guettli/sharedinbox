import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('root redirect (#464)', () {
    testWidgets(
      'navigating to "/" lands on the inbox instead of "Page Not Found"',
      (tester) async {
        final email = testEmail(subject: 'Redirected inbox mail');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/',
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

        // The inbox screen renders (redirect worked); go_router's default
        // "Page Not Found" error screen is not shown.
        expect(find.text('Redirected inbox mail'), findsOneWidget);
        expect(find.text('Page Not Found'), findsNothing);
      },
    );
  });
}
