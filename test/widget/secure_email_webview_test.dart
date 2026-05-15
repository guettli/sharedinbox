import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  // On Linux (the test host) the widget falls back to plain text extracted via
  // htmlToPlain().  These tests exercise that path.
  group('SecureEmailWebView (Linux plain-text fallback)', () {
    testWidgets('renders extracted text from HTML', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SecureEmailWebView(
            htmlBody: '<p>Hello <b>world</b></p>',
          ),
        ),
      );
      expect(find.textContaining('Hello'), findsOneWidget);
      expect(find.textContaining('world'), findsOneWidget);
    });

    testWidgets('strips HTML tags from body', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SecureEmailWebView(
            htmlBody:
                '<p>Clean text</p><br/><span style="color:red">More</span>',
          ),
        ),
      );
      expect(find.textContaining('<'), findsNothing);
      expect(find.textContaining('Clean text'), findsOneWidget);
    });

    testWidgets('shows SelectableText widget', (tester) async {
      await tester.pumpWidget(
        _wrap(const SecureEmailWebView(htmlBody: '<p>Test</p>')),
      );
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('toggling loadRemoteImages rebuilds without error',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SecureEmailWebView(htmlBody: '<p>Body</p>'),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          const SecureEmailWebView(
            htmlBody: '<p>Body</p>',
            loadRemoteImages: true,
          ),
        ),
      );
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('handles empty HTML body', (tester) async {
      await tester.pumpWidget(
        _wrap(const SecureEmailWebView(htmlBody: '')),
      );
      expect(find.byType(SelectableText), findsOneWidget);
    });
  });
}
