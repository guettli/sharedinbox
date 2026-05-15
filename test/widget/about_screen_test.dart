import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sharedinbox/ui/screens/about_screen.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class MockUrlLauncher extends Mock
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  String? launchedUrl;

  @override
  Future<bool> canLaunch(String? url) async => true;

  @override
  Future<bool> launchUrl(String? url, LaunchOptions? options) async {
    launchedUrl = url;
    return true;
  }
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'SharedInbox',
      packageName: 'org.sharedinbox',
      version: '1.2.3',
      buildNumber: '99',
      buildSignature: '',
    );
  });

  testWidgets('AboutScreen shows title and info table', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: AboutScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.textContaining('Version'), findsWidgets);
    expect(find.textContaining('1.2.3+99'), findsOneWidget);
    expect(find.textContaining('Resolution'), findsWidgets);
    expect(find.byIcon(Icons.copy), findsOneWidget);
    expect(find.byIcon(Icons.bug_report), findsOneWidget);
  });

  testWidgets('AboutScreen copy button puts markdown in clipboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    await tester.pumpWidget(
      const MaterialApp(home: AboutScreen()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(clipboardText, isNotNull);
    expect(clipboardText, contains('1.2.3+99'));
    expect(clipboardText, contains('Version'));
    expect(clipboardText, contains('Resolution'));
  });

  testWidgets('AboutScreen create-issue button opens Codeberg URL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final mock = MockUrlLauncher();
    UrlLauncherPlatform.instance = mock;

    await tester.pumpWidget(
      const MaterialApp(home: AboutScreen()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bug_report));
    await tester.pumpAndSettle();

    expect(
      mock.launchedUrl,
      contains('https://codeberg.org/guettli/sharedinbox/issues/new'),
    );
    expect(mock.launchedUrl, contains('1.2.3%2B99'));
  });
}
