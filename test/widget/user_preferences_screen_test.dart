import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/user_preferences_screen.dart';

import 'helpers.dart';

void main() {
  group('UserPreferencesScreen', () {
    testWidgets('shows both menu position options', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Menu bar position'), findsOneWidget);
      expect(find.text('Bottom (default)'), findsOneWidget);
      expect(find.text('Top'), findsOneWidget);
    });

    testWidgets('bottom option is selected by default', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final radioGroup = find.byType(RadioGroup<MenuPosition>);
      final widget = tester.widget<RadioGroup<MenuPosition>>(radioGroup);
      expect(widget.groupValue, MenuPosition.bottom);
    });

    testWidgets('tapping Top option updates the repo', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Top'));
      await tester.pumpAndSettle();

      final repo = ProviderScope.containerOf(
        tester.element(find.byType(UserPreferencesScreen)),
      ).read(userPreferencesRepositoryProvider)
          as FakeUserPreferencesRepository;

      expect(repo.menuPosition, MenuPosition.top);
    });
  });
}
