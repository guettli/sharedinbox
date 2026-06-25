import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/data/intents/mail_intent_handler.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';

import 'helpers.dart';

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
