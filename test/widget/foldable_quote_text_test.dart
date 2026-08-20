import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/foldable_quote_text.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );

const _longQuote = 'yes, please do that\n'
    '\n'
    'On Tue, 1 Jan 2024 at 10:00, Jane Doe <jane@example.com> wrote:\n'
    '> line one\n'
    '> line two\n'
    '> line three\n'
    '> line four\n'
    '> line five\n'
    '> line six';

void main() {
  group('FoldableQuoteText', () {
    testWidgets('folds a long trailing quote and reveals it on tap', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const FoldableQuoteText(_longQuote)));

      // Reply is visible, quote is hidden behind the affordance.
      expect(find.textContaining('yes, please do that'), findsOneWidget);
      expect(find.textContaining('> line one'), findsNothing);
      final showButton = find.textContaining('Show quoted text');
      expect(showButton, findsOneWidget);

      await tester.tap(showButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('> line one'), findsOneWidget);
      expect(find.textContaining('> line six'), findsOneWidget);
      expect(find.text('Hide quoted text'), findsOneWidget);

      await tester.tap(find.text('Hide quoted text'));
      await tester.pumpAndSettle();

      expect(find.textContaining('> line one'), findsNothing);
      expect(find.textContaining('Show quoted text'), findsOneWidget);
    });

    testWidgets('shows inline quoting fully expanded with no affordance', (
      tester,
    ) async {
      const inline = '> what about the deadline?\n'
          'It is next Friday.\n'
          '\n'
          '> and the budget?\n'
          'Still 5k.';
      await tester.pumpWidget(_wrap(const FoldableQuoteText(inline)));

      expect(find.textContaining('Show quoted text'), findsNothing);
      expect(find.textContaining('what about the deadline?'), findsOneWidget);
      expect(find.textContaining('Still 5k.'), findsOneWidget);
    });
  });
}
