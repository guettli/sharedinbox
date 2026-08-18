import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/try_connection_button.dart';

// LinkifiedText is a ConsumerWidget, so a ProviderScope must be in the tree.
Widget _wrap(Widget child) =>
    ProviderScope(child: MaterialApp(home: Scaffold(body: child)));

// Walks the rich-text spans and returns the tap recognizers attached to a span
// whose text matches [url] — mirrors how LinkifiedText renders hyperlinks.
List<GestureRecognizer> _linkRecognizersFor(WidgetTester tester, String url) {
  final recognizers = <GestureRecognizer>[];
  for (final richText in tester.widgetList<Text>(
    find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
  )) {
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == url && span.recognizer != null) {
          recognizers.add(span.recognizer!);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    walk(richText.textSpan!);
  }
  return recognizers;
}

void main() {
  group('TryConnectionButton', () {
    testWidgets('shows "Try connection" button when idle', (tester) async {
      await tester.pumpWidget(
        _wrap(const TryConnectionButton(testing: false, onPressed: null)),
      );
      expect(find.text('Try connection'), findsOneWidget);
    });

    testWidgets('shows spinner when testing', (tester) async {
      await tester.pumpWidget(
        _wrap(const TryConnectionButton(testing: true, onPressed: null)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Try connection'), findsNothing);
    });

    testWidgets('shows okMessage when provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TryConnectionButton(
            testing: false,
            onPressed: null,
            okMessage: 'Connected!',
          ),
        ),
      );
      expect(find.text('Connected!'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.error), findsNothing);
    });

    testWidgets('shows errorMessage when provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TryConnectionButton(
            testing: false,
            onPressed: null,
            errorMessage: 'Connection failed',
          ),
        ),
      );
      expect(find.text('Connection failed'), findsOneWidget);
      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('turns a URL in the errorMessage into a tappable link', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const TryConnectionButton(
            testing: false,
            onPressed: null,
            errorMessage:
                'Authentication failed. See https://support.google.com/mail '
                'for help.',
          ),
        ),
      );

      final recognizers =
          _linkRecognizersFor(tester, 'https://support.google.com/mail');
      expect(recognizers, hasLength(1));

      (recognizers.single as TapGestureRecognizer).onTap!();
      await tester.pumpAndSettle();

      expect(find.text('Open link?'), findsOneWidget);
      expect(find.text('https://support.google.com/mail'), findsOneWidget);
    });
  });
}
