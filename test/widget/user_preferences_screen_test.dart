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
      expect(find.text('Bottom (default)'), findsNWidgets(2));
      expect(find.text('Top'), findsNWidgets(2));
    });

    testWidgets('shows single mail view button position section', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Single mail view button position'),
        findsOneWidget,
      );
    });

    testWidgets('menu position bottom option is selected by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final radioGroups = find.byType(RadioGroup<MenuPosition>);
      final menuGroup =
          tester.widget<RadioGroup<MenuPosition>>(radioGroups.first);
      expect(menuGroup.groupValue, MenuPosition.bottom);
    });

    testWidgets('mail view button position bottom is selected by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final radioGroups = find.byType(RadioGroup<MenuPosition>);
      final mailViewGroup =
          tester.widget<RadioGroup<MenuPosition>>(radioGroups.last);
      expect(mailViewGroup.groupValue, MenuPosition.bottom);
    });

    testWidgets('tapping Top in menu position section updates the repo', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Top').first);
      await tester.pumpAndSettle();

      final repo = ProviderScope.containerOf(
        tester.element(find.byType(UserPreferencesScreen)),
      ).read(userPreferencesRepositoryProvider)
          as FakeUserPreferencesRepository;

      expect(repo.menuPosition, MenuPosition.top);
    });

    testWidgets(
        'tapping Top in mail view button position section updates the repo', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Top').last);
      await tester.pumpAndSettle();

      final repo = ProviderScope.containerOf(
        tester.element(find.byType(UserPreferencesScreen)),
      ).read(userPreferencesRepositoryProvider)
          as FakeUserPreferencesRepository;

      expect(repo.mailViewButtonPosition, MenuPosition.top);
    });

    testWidgets('shows after mail action section', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down to reveal the new section below the fold.
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      expect(find.text('After mail action'), findsOneWidget);
      expect(find.text('Next message (default)'), findsOneWidget);
      expect(find.text('Return to mailbox'), findsOneWidget);
    });

    testWidgets('after mail action next message is selected by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      final radioGroups = find.byType(RadioGroup<AfterMailViewAction>);
      final group =
          tester.widget<RadioGroup<AfterMailViewAction>>(radioGroups.first);
      expect(group.groupValue, AfterMailViewAction.nextMessage);
    });

    testWidgets('tapping Return to mailbox updates the repo', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/preferences',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Return to mailbox'));
      await tester.pumpAndSettle();

      final repo = ProviderScope.containerOf(
        tester.element(find.byType(UserPreferencesScreen)),
      ).read(userPreferencesRepositoryProvider)
          as FakeUserPreferencesRepository;

      expect(repo.afterMailViewAction, AfterMailViewAction.showMailbox);
    });
  });
}
