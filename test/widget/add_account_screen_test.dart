import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/add_account_screen.dart';

import 'helpers.dart';

// Wrap AddAccountScreen in a minimal GoRouter so context.pop() doesn't throw
// when the save succeeds in other tests.
Widget _buildScreen(List<Override> overrides) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (ctx, state) => const AddAccountScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
    ),
  );
}

List<Override> get _overrides => [
      accountRepositoryProvider.overrideWithValue(FakeAccountRepository()),
      mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
    ];

/// Drags the form's ListView so the bottom of the form (Save button) is
/// visible.  The drag distance is empirically large enough to clear all
/// fields in the default 800×600 test viewport.
Future<void> _scrollToBottom(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -2000));
  await tester.pumpAndSettle();
}

void main() {
  group('AddAccountScreen', () {
    testWidgets('renders fields visible at the top of the form',
        (tester) async {
      await tester.pumpWidget(_buildScreen(_overrides));
      await tester.pumpAndSettle();

      // These fields are near the top and visible without scrolling.
      expect(find.text('Add account'), findsOneWidget); // app-bar title
      expect(find.text('Display name'), findsOneWidget);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
    });

    testWidgets('Save button is reachable by scrolling', (tester) async {
      await tester.pumpWidget(_buildScreen(_overrides));
      await tester.pumpAndSettle();

      await _scrollToBottom(tester);

      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('shows "Required" validation errors when submitted empty',
        (tester) async {
      await tester.pumpWidget(_buildScreen(_overrides));
      await tester.pumpAndSettle();

      // Scroll to the Save button and tap it.
      await _scrollToBottom(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Scroll back to the top to see the first validation errors.
      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsWidgets);
    });

    testWidgets('IMAP SSL toggle is on by default', (tester) async {
      await tester.pumpWidget(_buildScreen(_overrides));
      await tester.pumpAndSettle();

      // The IMAP SSL tile is near the top and visible without scrolling.
      final imapTile = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('SSL/TLS').first,
        matching: find.byType(SwitchListTile),
      ));
      expect(imapTile.value, isTrue);
    });

    testWidgets('SMTP SSL toggle is off by default', (tester) async {
      await tester.pumpWidget(_buildScreen(_overrides));
      await tester.pumpAndSettle();

      // Scroll to reveal the SMTP section.
      await _scrollToBottom(tester);

      // After scrolling, there are two SwitchListTile widgets in the tree;
      // the last one is the SMTP SSL toggle.
      final tiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(tiles.last.value, isFalse, reason: 'SMTP SSL off by default');
    });
  });
}
