import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/data/intents/mail_intent_handler.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

/// Minimal mirror of the real route table: an initial location the intent has
/// to navigate away from, plus `/compose` reading the prefill `extra`.
GoRouter _composeRouter() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (ctx, state) =>
              const Scaffold(body: Center(child: Text('home'))),
        ),
        GoRoute(
          path: '/compose',
          builder: (ctx, state) {
            final extra = state.extra as Map<String, dynamic>?;
            return ComposeScreen(
              prefillTo: extra?['prefillTo'] as String?,
              prefillCc: extra?['prefillCc'] as String?,
              prefillSubject: extra?['prefillSubject'] as String?,
              prefillBody: extra?['prefillBody'] as String?,
            );
          },
        ),
      ],
    );

void main() {
  group('MailIntentHandler', () {
    testWidgets(
      'cold-start mailto: intent navigates to compose with prefilled fields',
      (tester) async {
        // Force the Android branch even though tests run on the host.
        final prevIsAndroid = MailIntentHandler.isAndroidForTest;
        MailIntentHandler.isAndroidForTest = () => true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailIntentHandler.methodChannel,
          (MethodCall call) async {
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
        addTearDown(() {
          MailIntentHandler.isAndroidForTest = prevIsAndroid;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MailIntentHandler.methodChannel,
            null,
          );
        });

        final router = _composeRouter();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...baseOverrides(accounts: [kTestAccount]),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
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
        final prevIsAndroid = MailIntentHandler.isAndroidForTest;
        MailIntentHandler.isAndroidForTest = () => true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailIntentHandler.methodChannel,
          (MethodCall call) async => <String, Object?>{
            'to': 'dana@example.com',
            'subject': 'Race',
            'attachmentPaths': <String>[],
          },
        );
        addTearDown(() {
          MailIntentHandler.isAndroidForTest = prevIsAndroid;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MailIntentHandler.methodChannel,
            null,
          );
        });

        final router = _composeRouter();
        // Start the bridge *before* the first frame, the way `main.dart` does
        // from `initState`, so the intent resolves around the time the router
        // settles its initial location rather than long after it (#862).
        final handler = MailIntentHandler(router: router);
        addTearDown(handler.dispose);
        final initialized = handler.initialize();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...baseOverrides(accounts: [kTestAccount]),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
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
        final prevIsAndroid = MailIntentHandler.isAndroidForTest;
        MailIntentHandler.isAndroidForTest = () => true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailIntentHandler.methodChannel,
          (MethodCall call) async => null,
        );
        MockStreamHandlerEventSink? sink;
        tester.binding.defaultBinaryMessenger.setMockStreamHandler(
          MailIntentHandler.eventChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              sink = events;
            },
          ),
        );
        addTearDown(() {
          MailIntentHandler.isAndroidForTest = prevIsAndroid;
          tester.binding.defaultBinaryMessenger
            ..setMockMethodCallHandler(MailIntentHandler.methodChannel, null)
            ..setMockStreamHandler(MailIntentHandler.eventChannel, null);
        });

        final router = _composeRouter();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...baseOverrides(accounts: [kTestAccount]),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
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
        final prevIsAndroid = MailIntentHandler.isAndroidForTest;
        MailIntentHandler.isAndroidForTest = () => true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailIntentHandler.methodChannel,
          (MethodCall call) async => null,
        );
        addTearDown(() {
          MailIntentHandler.isAndroidForTest = prevIsAndroid;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MailIntentHandler.methodChannel,
            null,
          );
        });

        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            GoRoute(
              path: '/home',
              builder: (ctx, state) =>
                  const Scaffold(body: Center(child: Text('home'))),
            ),
            GoRoute(
              path: '/compose',
              builder: (ctx, state) =>
                  const Scaffold(body: Center(child: Text('compose'))),
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository(),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
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
      final prevIsAndroid = MailIntentHandler.isAndroidForTest;
      MailIntentHandler.isAndroidForTest = () => false;
      var channelCalled = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MailIntentHandler.methodChannel,
        (MethodCall call) async {
          channelCalled = true;
          return null;
        },
      );
      addTearDown(() {
        MailIntentHandler.isAndroidForTest = prevIsAndroid;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailIntentHandler.methodChannel,
          null,
        );
      });

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (ctx, state) =>
                const Scaffold(body: Center(child: Text('home'))),
          ),
        ],
      );

      final handler = MailIntentHandler(router: router);
      await handler.initialize();
      addTearDown(handler.dispose);

      expect(channelCalled, isFalse);
    });
  });
}
