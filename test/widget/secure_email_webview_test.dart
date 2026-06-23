import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';

void _expectLightMode(String html) {
  expect(html, contains('color-scheme" content="light"'));
  expect(html, contains('color-scheme: light'));
  expect(html, contains('background-color: #ffffff'));
  expect(html, contains('color: #000000'));
}

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('buildEmailHtml', () {
    test(
      'forces light color-scheme to prevent black-on-black in dark mode',
      () {
        _expectLightMode(buildEmailHtml('<p>Hello</p>'));
      },
    );

    test('includes email body content', () {
      final html = buildEmailHtml('<p>Test body</p>');
      expect(html, contains('<p>Test body</p>'));
    });

    test('blocks remote images by default', () {
      final html = buildEmailHtml('<p>x</p>');
      expect(html, contains('img-src data: blob:'));
      expect(html, isNot(contains('img-src https:')));
    });

    test('allows remote images when loadRemoteImages is true', () {
      final html = buildEmailHtml('<p>x</p>', loadRemoteImages: true);
      expect(html, contains('https: http: data: blob:'));
      _expectLightMode(html);
    });

    test('prevents horizontal overflow so wide HTML emails are not cut off',
        () {
      final html = buildEmailHtml(
        '<table width="600"><tr><td>x</td></tr></table>',
      );
      // Body clips overflow so fixed-width email tables don't escape the viewport.
      expect(html, contains('overflow-x: hidden'));
      // Tables are forced to full viewport width so fixed pixel widths don't overflow.
      expect(html, contains('table { width: 100%'));
      // All elements are capped at viewport width via max-width.
      expect(html, contains('max-width: 100%'));
      // Pre-formatted text wraps instead of stretching the page.
      expect(html, contains('white-space: pre-wrap'));
    });
  });

  group('buildLinkDialogSpans', () {
    // Verifies that the registered domain (last two DNS labels) is rendered in
    // a bold span while the rest of the URL stays plain — that is what makes
    // a phishing host like `evil.com/login.bank.com` visually distinguishable.
    List<TextSpan> spansFor(String url) =>
        buildLinkDialogSpans(url, Uri.parse(url));

    void expectSplit(
      String url, {
      required String before,
      required String bold,
      required String after,
    }) {
      final spans = spansFor(url);
      expect(spans, hasLength(3));
      expect(spans[0].text, before);
      expect(spans[1].text, bold);
      expect(spans[1].style?.fontWeight, FontWeight.bold);
      expect(spans[2].text, after);
    }

    test('bolds registered domain within a typical https URL', () {
      expectSplit(
        'https://www.example.com/path?q=1',
        before: 'https://www.',
        bold: 'example.com',
        after: '/path?q=1',
      );
    });

    test('bolds the whole host when there is no subdomain', () {
      expectSplit(
        'https://example.com/',
        before: 'https://',
        bold: 'example.com',
        after: '/',
      );
    });

    test('preserves the original URL casing', () {
      expectSplit(
        'HTTPS://WWW.Example.COM/Path',
        before: 'HTTPS://WWW.',
        bold: 'Example.COM',
        after: '/Path',
      );
    });

    test('handles deep subdomains by bolding only the last two labels', () {
      expectSplit(
        'https://a.b.c.example.co/x',
        before: 'https://a.b.c.',
        bold: 'example.co',
        after: '/x',
      );
    });

    test('handles URLs with a port', () {
      expectSplit(
        'http://example.com:8080/x',
        before: 'http://',
        bold: 'example.com',
        after: ':8080/x',
      );
    });

    test('returns the URL as a single plain span when there is no host', () {
      final spans = spansFor('mailto:alice@example.com');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'mailto:alice@example.com');
      expect(spans.single.style?.fontWeight, isNull);
    });
  });

  // On Linux (the test host) the widget falls back to plain text extracted via
  // htmlToPlain().  These tests exercise that path.
  group('SecureEmailWebView (Linux plain-text fallback)', () {
    testWidgets('renders extracted text from HTML', (tester) async {
      await tester.pumpWidget(
        _wrap(const SecureEmailWebView(htmlBody: '<p>Hello <b>world</b></p>')),
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

    testWidgets('toggling loadRemoteImages rebuilds without error', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SecureEmailWebView(htmlBody: '<p>Body</p>')),
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
      await tester.pumpWidget(_wrap(const SecureEmailWebView(htmlBody: '')));
      expect(find.byType(SelectableText), findsOneWidget);
    });
  });
}
