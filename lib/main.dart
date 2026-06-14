import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/core/sync/background_sync.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/router.dart';
import 'package:sharedinbox/ui/screens/crash_screen.dart';
import 'package:sharedinbox/ui/widgets/error_boundary.dart';
import 'package:stack_trace/stack_trace.dart' as stack_trace;

void main({List<Override> overrides = const []}) {
  unawaited(
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();

        // Dart's async machinery propagates stack traces in chain format
        // (with '===== asynchronous gap =====' separators). Flutter's
        // StackFrame parser asserts on those lines, so strip them first.
        FlutterError.demangleStackTrace = (StackTrace s) {
          if (s is stack_trace.Chain) return s.toTrace().vmTrace;
          if (s is stack_trace.Trace) return s.vmTrace;
          return s;
        };

        // Catch errors during build (e.g. layout exceptions). The boundary-
        // aware widget routes the error to an enclosing ErrorBoundary if one
        // exists in the failing widget's ancestry, otherwise substitutes the
        // failing slot with a full-screen CrashScreen.
        ErrorWidget.builder = (details) => BoundaryAwareErrorWidget(
              details: details,
              fallback: (d) => CrashScreen(
                exception: d.exception,
                stackTrace: d.stack,
              ),
            );

        // Catch framework-level errors (e.g. from gestures, timers). For
        // widget/rendering library errors the framework also substitutes the
        // failing widget via ErrorWidget.builder above, so a global
        // runApp(CrashScreen) would defeat any ErrorBoundary placed in the
        // tree. Only escalate to the full-screen CrashScreen for errors that
        // ErrorWidget.builder cannot recover from.
        FlutterError.onError = (details) {
          FlutterError.presentError(details);
          if (_isWidgetTreeError(details)) return;
          runApp(
            CrashScreen(
              exception: details.exception,
              stackTrace: details.stack,
            ),
          );
        };

        await initDatabasePath();
        if (Platform.isAndroid) {
          await initNotifications();
          await registerBackgroundSync();
          await _registerPrefetchTaskFromStoredPrefs();
        }
        runApp(
          ProviderScope(overrides: overrides, child: const SharedInboxApp()),
        );
      },
      // This handler runs in the parent zone — runApp cannot be called here.
      // Framework errors are already handled by FlutterError.onError above.
      (error, stack) => FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      ),
    ),
  );
}

/// True when [details] comes from the widget build or rendering pipeline. The
/// framework already substitutes the failing widget via `ErrorWidget.builder`
/// for these, so we suppress the global runApp(CrashScreen) to let any
/// in-tree [ErrorBoundary] keep the rest of the screen alive.
bool _isWidgetTreeError(FlutterErrorDetails details) {
  final lib = details.library;
  return lib == 'widgets library' || lib == 'rendering library';
}

/// Reads the stored prefetch preference and registers the WorkManager task
/// with the correct network constraint for it. Opens and immediately closes
/// a temporary DB connection; safe because initDatabasePath() has already run.
Future<void> _registerPrefetchTaskFromStoredPrefs() async {
  final db = AppDatabase();
  try {
    final row = await db.select(db.userPreferences).getSingleOrNull();
    final mode = PrefetchMode.fromString(row?.prefetchMode);
    await registerBodyPrefetchTask(mode);
  } finally {
    await db.close();
  }
}

class SharedInboxApp extends ConsumerStatefulWidget {
  const SharedInboxApp({super.key});

  @override
  ConsumerState<SharedInboxApp> createState() => _SharedInboxAppState();
}

const _kGitHash = String.fromEnvironment('GIT_HASH');

class _SharedInboxAppState extends ConsumerState<SharedInboxApp> {
  @override
  void initState() {
    super.initState();
    // Start background IMAP sync once — runs for the lifetime of the app.
    ref.read(syncManagerProvider).start();
    ref.read(reliabilityRunnerProvider).start();
    // Resume any saved UnifiedPush distributor registration so push wake-ups
    // start arriving again as soon as possible after launch.
    unawaited(ref.read(unifiedPushServiceProvider).initialize());
    if (_kGitHash.isNotEmpty) {
      unawaited(
        ref.read(dbProvider).recordInstalledVersionIfNew(_kGitHash),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'sharedinbox.de',
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    ),
    useMaterial3: true,
    splashFactory: NoSplash.splashFactory,
  );
}
