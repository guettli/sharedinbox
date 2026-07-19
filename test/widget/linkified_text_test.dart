import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/linkified_text.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );

// Collects every gesture recognizer attached to any TextSpan under [text],
// so tests can invoke the exact same tap callback that a real tap would.
List<GestureRecognizer> _recognizersFor(WidgetTester tester, String text) {
  final richText = tester.widget<Text>(
    find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
  );
  final root = richText.textSpan!;
  final recognizers = <GestureRecognizer>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text == text && span.recognizer != null) {
        recognizers.add(span.recognizer!);
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(root);
  return recognizers;
}

void main() {
  group('LinkifiedText', () {
    testWidgets('wraps plain text in a SelectionArea so it can be selected', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LinkifiedText('just some text')));

      expect(find.byType(SelectionArea), findsOneWidget);
      final w = tester.widget<Text>(
        find.descendant(
          of: find.byType(SelectionArea),
          matching: find.byType(Text),
        ),
      );
      // No rich spans — the .rich constructor is not used for plain text.
      expect(w.textSpan, isNull);
      expect(w.data, 'just some text');
    });

    testWidgets('renders text containing a URL as rich Text in SelectionArea', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const LinkifiedText('See https://example.com for info.')),
      );

      expect(find.byType(SelectionArea), findsOneWidget);
      final w = tester.widget<Text>(
        find.descendant(
          of: find.byType(SelectionArea),
          matching:
              find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
        ),
      );
      expect(w.textSpan, isNotNull);

      final rec = _recognizersFor(tester, 'https://example.com');
      expect(rec, hasLength(1));
    });

    testWidgets('opens confirmation dialog on link tap', (tester) async {
      await tester.pumpWidget(
        _wrap(const LinkifiedText('open https://example.com now')),
      );

      final rec = _recognizersFor(tester, 'https://example.com').single
          as TapGestureRecognizer;
      rec.onTap!();
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      // The URL is shown inside the dialog so users can verify it.
      expect(find.text('https://example.com'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Open in browser'), findsOneWidget);
    });

    testWidgets('Cancel dismisses the dialog without launching', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const LinkifiedText('open https://example.com now')),
      );

      final rec = _recognizersFor(tester, 'https://example.com').single
          as TapGestureRecognizer;
      rec.onTap!();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsNothing);
    });

    testWidgets('applies the provided text style as the base style', (
      tester,
    ) async {
      const style = TextStyle(color: Color(0xFF123456), fontSize: 17);
      await tester.pumpWidget(_wrap(const LinkifiedText('hi', style: style)));

      final w = tester.widget<Text>(
        find.descendant(
          of: find.byType(SelectionArea),
          matching: find.byType(Text),
        ),
      );
      expect(w.style, style);
    });
  });
}
