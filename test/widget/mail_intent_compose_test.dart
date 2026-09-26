import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/data/intents/mail_intent_handler.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

/// Minimal mirror of the real route table: an initial location the intent has
/// to navigate away from, plus `/compose` reading the prefill `extra`.
GoRouter _composeRouter() => homeAndComposeRouter(
      compose: (state) {
        final extra = state.extra as Map<String, dynamic>?;
        return ComposeScreen(
          prefillTo: extra?['prefillTo'] as String?,
          prefillCc: extra?['prefillCc'] as String?,
          prefillSubject: extra?['prefillSubject'] as String?,
          prefillBody: extra?['prefillBody'] as String?,
        );
      },
    );

/// A `/compose` that renders a bare marker instead of the real screen, for the
/// tests that only care *whether* navigation happened.
GoRouter _composeStubRouter() => homeAndComposeRouter(
      compose: (_) => const Scaffold(body: Center(child: Text('compose'))),
    );

/// Forces the Android branch (these tests run on the host) and installs the mock
/// platform channels, restoring all of it on teardown.
///
/// Extracted rather than repeated in each test: five copies of this preamble is
/// what the duplication gate flags, and the teardown is the half that is easy to
/// get wrong -- a leaked `isAndroidForTest` makes some later, unrelated test fail
/// for no visible reason.
void _useMockIntentChannels(
  WidgetTester tester, {
  bool android = true,
  Future<Object?>? Function(MethodCall call)? onMethodCall,
  MockStreamHandler? streamHandler,
}) {
  final prevIsAndroid = MailIntentHandler.isAndroidForTest;
  MailIntentHandler.isAndroidForTest = () => android;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    MailIntentHandler.methodChannel,
    onMethodCall ?? (call) async => null,
  );
  if (streamHandler != null) {
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      MailIntentHandler.eventChannel,
      streamHandler,
    );
  }
  addTearDown(() {
    MailIntentHandler.isAndroidForTest = prevIsAndroid;
    tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(MailIntentHandler.methodChannel, null)
      ..setMockStreamHandler(MailIntentHandler.eventChannel, null);
  });
}

/// Pumps the app around [router]. Deliberately does NOT settle: the cold-start
/// test needs to start the handler before the first frame, so each test decides
/// when to pump again.
Future<void> _pumpApp(
  WidgetTester tester,
  GoRouter router, {
  List<Override>? overrides,
}) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: overrides ?? baseOverrides(accounts: [kTestAccount]),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

void main() {
  group('MailIntentHandler', () {
    testWidgets(
      'cold-start mailto: intent navigates to compose with prefilled fields',
      (tester) async {
        _useMockIntentChannels(
          tester,
          onMethodCall: (call) async {
            if (call.method == 'getInitialIntent') {
              return <String, Object?>{
                'to': 'bob@example.com',
                'subject': 'Hi there',
                'body': 'Line1\nLine2',
                'attachmentPaths': <String>[],
              };
            }
            return null;
          },
        );

        final router = _composeRouter();
        await _pumpApp(tester, router);
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);

        final handler = MailIntentHandler(router: router);
        await handler.initialize();
        await tester.pumpAndSettle();
        addTearDown(handler.dispose);

        // Compose screen is now on top, with the prefilled fields visible.
        expect(find.text('Compose'), findsOneWidget);
        expect(
          find.widgetWithText(TextFormField, 'bob@example.com'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextFormField, 'Hi there'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextFormField, 'Line1\nLine2'),
          findsOneWidget,
        );
      },
    );

    // NOTE: this does NOT reproduce a router-still-settling interleaving, and an
    // earlier version of this file claimed it did. pumpWidget attaches the root
    // synchronously, so the Router has already parsed the initial location before
    // the mocked platform reply can resolve on the next microtask. It passes with
    // the post-frame push reverted. Keep it as a plain end-to-end regression test
    // for the cold-start path; making it load-bearing requires first knowing the
    // real mechanism, which is not yet confirmed on a device (#862).
    testWidgets(
      'cold-start intent opens compose with prefills',
      (tester) async {
        _useMockIntentChannels(
          tester,
          onMethodCall: (call) async => <String, Object?>{
            'to': 'dana@example.com',
            'subject': 'Race',
            'attachmentPaths': <String>[],
          },
        );

        final router = _composeRouter();
        // Start the bridge *before* the first frame, the way `main.dart` does
        // from `initState`. That is the shape of the real launch, which is why it
        // is worth covering -- but see the note above: it does not actually
        // interleave with the router's initial parse.
        final handler = MailIntentHandler(router: router);
        addTearDown(handler.dispose);
        final initialized = handler.initialize();

        await _pumpApp(tester, router);
        await initialized;
        await tester.pumpAndSettle();

        expect(find.text('Compose'), findsOneWidget);
        expect(
          find.widgetWithText(TextFormField, 'dana@example.com'),
          findsOneWidget,
        );
      },
    );

    // First end-to-end coverage of the warm-start/event-channel path, which had
    // none. It does not gate the subscribe-before-await reordering: it fires the
    // event only after `await initialize()` and a pumpAndSettle, by which point
    // even the old ordering had attached its listener. The Kotlin stash/replay
    // that backs this path has no test at all -- it is not reachable from Dart.
    testWidgets(
      'warm-start intent (onNewIntent) navigates to compose',
      (tester) async {
        MockStreamHandlerEventSink? sink;
        _useMockIntentChannels(
          tester,
          streamHandler: MockStreamHandler.inline(
            onListen: (arguments, events) {
              sink = events;
            },
          ),
        );

        final router = _composeRouter();
        await _pumpApp(tester, router);
        await tester.pumpAndSettle();

        final handler = MailIntentHandler(router: router);
        await handler.initialize();
        await tester.pumpAndSettle();
        addTearDown(handler.dispose);

        // The app is up and idle on the inbox — now the browser hands over a
        // mailto: link, which Android delivers via onNewIntent.
        expect(find.text('home'), findsOneWidget);
        expect(sink, isNotNull);
        sink!.success(<String, Object?>{
          'to': 'carol@example.com',
          'cc': 'dave@example.com',
          'subject': 'Lunch?',
          'attachmentPaths': <String>[],
        });
        await tester.pumpAndSettle();

        expect(find.text('Compose'), findsOneWidget);
        expect(
          find.widgetWithText(TextFormField, 'carol@example.com'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextFormField, 'dave@example.com'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextFormField, 'Lunch?'), findsOneWidget);
      },
    );

    testWidgets(
      'no-op when getInitialIntent returns null (normal launch)',
      (tester) async {
        _useMockIntentChannels(tester);

        final router = _composeStubRouter();
        await _pumpApp(
          tester,
          router,
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(),
            ),
          ],
        );
        await tester.pumpAndSettle();

        final handler = MailIntentHandler(router: router);
        await handler.initialize();
        await tester.pumpAndSettle();
        addTearDown(handler.dispose);

        // Still on home — no navigation happened.
        expect(find.text('home'), findsOneWidget);
        expect(find.text('compose'), findsNothing);
      },
    );

    testWidgets('skipped entirely on non-Android platforms', (tester) async {
      var channelCalled = false;
      _useMockIntentChannels(
        tester,
        android: false,
        onMethodCall: (call) async {
          channelCalled = true;
          return null;
        },
      );

      final router = _composeStubRouter();

      final handler = MailIntentHandler(router: router);
      await handler.initialize();
      addTearDown(handler.dispose);

      expect(channelCalled, isFalse);
    });
  });
}
