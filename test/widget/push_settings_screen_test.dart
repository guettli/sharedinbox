import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/screens/push_settings_screen.dart';

import 'helpers.dart';

void main() {
  group('PushSettingsScreen', () {
    // The widget test environment is Linux desktop, where
    // UnifiedPushService.isSupported is false. The screen should render the
    // "not supported" hint and not crash trying to enumerate distributors.
    testWidgets('renders the Not-supported message on desktop', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/push',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PushSettingsScreen), findsOneWidget);
      expect(find.text('UnifiedPush'), findsOneWidget); // appbar title
      expect(find.text('Not supported on this platform'), findsOneWidget);
    });

    testWidgets('appbar shows the UnifiedPush title', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/push',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final appBar = find.byType(AppBar);
      expect(appBar, findsOneWidget);
      expect(
        find.descendant(of: appBar, matching: find.text('UnifiedPush')),
        findsOneWidget,
      );
    });
  });
}
