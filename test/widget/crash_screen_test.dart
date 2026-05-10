import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
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
  testWidgets('CrashScreen shows error details and has a report button',
      (tester) async {
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
    expect(
      mock.launchedUrl,
      contains('body=Error%3A%20TestException%3A%20something%20broke'),
    );
  });
}
