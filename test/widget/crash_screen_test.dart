import 'package:flutter/material.dart';
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
