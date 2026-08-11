import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/screens/combined_inbox_screen.dart';

import 'helpers.dart';

void main() {
  group('root redirect (#464)', () {
    testWidgets(
      'navigating to "/" lands on the inbox instead of "Page Not Found"',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/',
            overrides: baseOverrides(accounts: [kTestAccount]),
          ),
        );
        await tester.pumpAndSettle();

        // The redirect resolved `/` to the inbox; go_router's default
        // "Page Not Found" error screen is not shown.
        expect(find.byType(CombinedInboxScreen), findsOneWidget);
        expect(find.text('Page Not Found'), findsNothing);
      },
    );
  });
}
