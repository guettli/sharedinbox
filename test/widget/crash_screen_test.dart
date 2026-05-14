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

    expect(
      mock.launchedUrl,
      contains('https://codeberg.org/guettli/sharedinbox/issues/new'),
    );
    expect(
      mock.launchedUrl,
      contains('title=Crash%3A%20TestException%3A%20something%20broke'),
    );
    expect(mock.launchedUrl, contains('App%20Version%3A%201.0.0%2B42'));
    expect(mock.launchedUrl, contains('TestException%3A%20something%20broke'));
  });
}
