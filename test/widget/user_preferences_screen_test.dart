import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/user_preferences_screen.dart';

import 'helpers.dart';

/// Opens the preferences screen with the default fakes.
Future<void> _pumpPreferences(WidgetTester tester) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/preferences',
      overrides: baseOverrides(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Scrolls the preferences list until [text] (below the fold) is on screen.
Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

/// Taps [text] and returns the fake repository the screen writes to.
Future<FakeUserPreferencesRepository> _tapAndGetRepo(
  WidgetTester tester,
  String text,
) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(UserPreferencesScreen)),
  ).read(userPreferencesRepositoryProvider) as FakeUserPreferencesRepository;
}

/// Returns the selected value of the first `RadioGroup<T>` on screen.
T? _groupValue<T>(WidgetTester tester) =>
    tester.widget<RadioGroup<T>>(find.byType(RadioGroup<T>).first).groupValue;

void main() {
  group('UserPreferencesScreen', () {
    testWidgets('shows both menu position options', (tester) async {
      await _pumpPreferences(tester);

      expect(find.text('Menu bar position'), findsOneWidget);
      expect(find.text('Bottom (default)'), findsOneWidget);
      expect(find.text('Top'), findsOneWidget);
    });

    testWidgets('does not show removed mail view button position section', (
      tester,
    ) async {
      // Removed in #1093: no screen read the preference since #625.
      await _pumpPreferences(tester);

      expect(find.text('Single mail view button position'), findsNothing);
      expect(find.byType(RadioGroup<MenuPosition>), findsOneWidget);
    });

    testWidgets('menu position bottom option is selected by default', (
      tester,
    ) async {
      await _pumpPreferences(tester);

      expect(_groupValue<MenuPosition>(tester), MenuPosition.bottom);
    });

    testWidgets('tapping Top in menu position section updates the repo', (
      tester,
    ) async {
      await _pumpPreferences(tester);

      final repo = await _tapAndGetRepo(tester, 'Top');

      expect(repo.menuPosition, MenuPosition.top);
    });

    testWidgets('shows after mail action section', (tester) async {
      await _pumpPreferences(tester);
      await _scrollTo(tester, 'After mail action');

      expect(find.text('After mail action'), findsOneWidget);
      expect(find.text('Next message (default)'), findsOneWidget);
      expect(find.text('Return to mailbox'), findsOneWidget);
    });

    testWidgets('after mail action next message is selected by default', (
      tester,
    ) async {
      await _pumpPreferences(tester);
      await _scrollTo(tester, 'Return to mailbox');

      expect(
        _groupValue<AfterMailViewAction>(tester),
        AfterMailViewAction.nextMessage,
      );
    });

    testWidgets('tapping Return to mailbox updates the repo', (tester) async {
      await _pumpPreferences(tester);
      await _scrollTo(tester, 'Return to mailbox');

      final repo = await _tapAndGetRepo(tester, 'Return to mailbox');

      expect(repo.afterMailViewAction, AfterMailViewAction.showMailbox);
    });
  });
}
