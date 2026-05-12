import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/router.dart';
import 'package:sharedinbox/ui/screens/crash_screen.dart';

void main({List<Override> overrides = const []}) async {
  unawaited(
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();

        // Catch errors during build (e.g. layout exceptions) and show CrashScreen.
        ErrorWidget.builder = (details) => CrashScreen(
              exception: details.exception,
              stackTrace: details.stack,
            );

        // Catch framework-level errors (e.g. from gestures, timers).
        FlutterError.onError = (details) {
          FlutterError.presentError(details);
          runApp(
            CrashScreen(
              exception: details.exception,
              stackTrace: details.stack,
            ),
          );
        };

        await initDatabasePath();
        runApp(
          ProviderScope(overrides: overrides, child: const SharedInboxApp()),
        );
      },
      (error, stack) {
        // Catch unhandled async errors.
        runApp(CrashScreen(exception: error, stackTrace: stack));
      },
    ),
  );
}

class SharedInboxApp extends ConsumerStatefulWidget {
  const SharedInboxApp({super.key});

  @override
  ConsumerState<SharedInboxApp> createState() => _SharedInboxAppState();
}

class _SharedInboxAppState extends ConsumerState<SharedInboxApp> {
  @override
  void initState() {
    super.initState();
    // Start background IMAP sync once — runs for the lifetime of the app.
    ref.read(syncManagerProvider).start();
    ref.read(reliabilityRunnerProvider).start();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SharedInbox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
