import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/linkified_text.dart';

import 'helpers.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );

/// Pumps a [LinkifiedText] containing one URL, taps the link and waits for
/// the confirmation dialog to appear.
Future<void> _openLinkDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    _wrap(const LinkifiedText('open https://example.com now')),
  );

  final rec = linkRecognizersFor(tester, 'https://example.com').single
      as TapGestureRecognizer;
  rec.onTap!();
  await tester.pumpAndSettle();
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

      final rec = linkRecognizersFor(tester, 'https://example.com');
      expect(rec, hasLength(1));
    });

    testWidgets('opens confirmation dialog on link tap', (tester) async {
      await _openLinkDialog(tester);

      expect(find.text('Open link?'), findsOneWidget);
      // The URL is shown inside the dialog so users can verify it.
      expect(find.text('https://example.com'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Open in browser'), findsOneWidget);
    });

    testWidgets('Cancel dismisses the dialog without launching', (
      tester,
    ) async {
      await _openLinkDialog(tester);

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

    testWidgets('linkStyle overrides the default link style', (tester) async {
      const linkStyle = TextStyle(color: Color(0xFF00FF00));
      await tester.pumpWidget(
        _wrap(
          const LinkifiedText(
            'see https://example.com',
            linkStyle: linkStyle,
          ),
        ),
      );

      final w = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
      );
      final link = (w.textSpan! as TextSpan)
          .children!
          .whereType<TextSpan>()
          .singleWhere((s) => s.text == 'https://example.com');
      expect(link.style, linkStyle);
    });
  });
}
