import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sharedinbox/ui/screens/crash_screen.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class MockUrlLauncher extends Mock
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  String? launchedUrl;
  LaunchOptions? launchOptions;

  @override
  Future<bool> canLaunch(String? url) async => true;

  @override
  Future<bool> launchUrl(String? url, LaunchOptions? options) async {
    launchedUrl = url;
    launchOptions = options;
    return true;
  }
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'SharedInbox',
      packageName: 'org.sharedinbox',
      version: '1.0.0',
      buildNumber: '42',
      buildSignature: '',
    );
  });

  testWidgets('CrashScreen shows error details and has a report button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final mock = MockUrlLauncher();
    UrlLauncherPlatform.instance = mock;

    const exception = 'TestException: something broke';
    final stackTrace = StackTrace.current;

    await tester.pumpWidget(
      MaterialApp(
        home: CrashScreen(exception: exception, stackTrace: stackTrace),
      ),
    );

    expect(find.textContaining('TestException'), findsOneWidget);
    expect(find.text('Report Issue on Codeberg'), findsOneWidget);

    await tester.tap(find.text('Report Issue on Codeberg'));
    await tester.pumpAndSettle();

    // Regression for #146: URL must contain only the title, NOT the full
    // report body.  Long stack traces caused "create issue failed" by
    // exceeding browser URL-length limits.  The report is copied to clipboard
    // so the user can paste it into the issue body.
    expect(
      mock.launchedUrl,
      contains('https://codeberg.org/guettli/sharedinbox/issues/new'),
    );
    expect(
      mock.launchedUrl,
      contains('title=Crash%3A%20TestException%3A%20something%20broke'),
    );
    expect(mock.launchedUrl, isNot(contains('&body=')));
    expect(mock.launchedUrl, isNot(contains('App%20Version')));
    expect(mock.launchedUrl, isNot(contains('Stack%20Trace')));
  });

  testWidgets(
    'CrashScreen copy-to-clipboard includes version and platform info',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      const exception = 'TestException: clipboard test';
      final stackTrace = StackTrace.current;

      await tester.pumpWidget(
        MaterialApp(
          home: CrashScreen(exception: exception, stackTrace: stackTrace),
        ),
      );

      await tester.tap(find.text('Copy to Clipboard'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('App Version: 1.0.0+42'));
      expect(clipboardText, contains('Build Mode:'));
      expect(clipboardText, contains('Platform:'));
      expect(clipboardText, contains('Dart:'));
      expect(clipboardText, contains('Timestamp:'));
      expect(clipboardText, contains('TestException: clipboard test'));
      // GIT_HASH is empty in test builds — no Git Commit line expected
      expect(clipboardText, isNot(contains('Git Commit:')));
    },
  );

  testWidgets(
    'CrashScreen shows git hash as clickable link above stacktrace',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mock = MockUrlLauncher();
      UrlLauncherPlatform.instance = mock;

      const exception = 'TestException: git hash test';
      final stackTrace = StackTrace.current;
      const testHash = 'abc1234';

      await tester.pumpWidget(
        CrashScreen(
          exception: exception,
          stackTrace: stackTrace,
          gitHash: testHash,
        ),
      );

      // Git hash link should be present
      final gitLinkFinder = find.textContaining('Git Commit: abc1234');
      expect(gitLinkFinder, findsOneWidget);

      // Link must appear above the stack trace
      final stackTraceFinder = find.text('Stack Trace:');
      expect(
        tester.getTopLeft(gitLinkFinder).dy,
        lessThan(tester.getTopLeft(stackTraceFinder).dy),
      );

      // Tapping the link should open the Codeberg commit URL
      await tester.tap(gitLinkFinder);
      await tester.pumpAndSettle();

      expect(
        mock.launchedUrl,
        equals('https://codeberg.org/guettli/sharedinbox/commit/abc1234'),
      );
    },
  );

  testWidgets(
    'CrashScreen shows version, build mode, and platform in the UI',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      const exception = 'TestException: info row test';
      final stackTrace = StackTrace.current;

      await tester.pumpWidget(
        MaterialApp(
          home: CrashScreen(exception: exception, stackTrace: stackTrace),
        ),
      );
      await tester.pumpAndSettle();

      // Info row shows app version (from mock), build mode, and platform OS.
      expect(find.textContaining('1.0.0+42'), findsWidgets);
      // In test builds kDebugMode is true.
      expect(find.textContaining('debug'), findsOneWidget);
      // Platform OS is always present (linux in CI, android/ios on device).
      expect(
        find.textContaining(RegExp(r'linux|android|ios|windows|macos')),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'CrashScreen used as root widget — buttons work without ScaffoldMessenger crash',
    (tester) async {
      // Regression test for: ScaffoldMessenger.of(context) null-crash when
      // CrashScreen is the root widget (runApp path after startup crash).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mock = MockUrlLauncher();
      UrlLauncherPlatform.instance = mock;

      const exception = 'TestException: startup crash';
      final stackTrace = StackTrace.current;

      // Pump CrashScreen directly as the root — no parent MaterialApp.
      await tester.pumpWidget(
        CrashScreen(exception: exception, stackTrace: stackTrace),
      );

      expect(find.textContaining('TestException'), findsOneWidget);

      // Tapping 'Report Issue on Codeberg' must not crash. Previously
      // ScaffoldMessenger.of(context) threw because context was above the
      // MaterialApp that CrashScreen itself creates.
      await tester.tap(find.text('Report Issue on Codeberg'));
      await tester.pumpAndSettle();

      expect(
        mock.launchedUrl,
        contains('https://codeberg.org/guettli/sharedinbox/issues/new'),
      );
    },
  );
}
