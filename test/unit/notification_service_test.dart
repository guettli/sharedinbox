import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression test for https://codeberg.org/guettli/sharedinbox/issues/146:
  // On some Android devices the flutter_local_notifications plugin channel is
  // absent at startup, throwing MissingPluginException (or a similar error).
  // initNotifications() must absorb the failure and let the app continue.
  test(
      'initNotifications completes without throwing when plugin is unavailable',
      () async {
    // In the unit-test environment the native plugin is not registered, so
    // _plugin.initialize() throws. The fix catches it and keeps _initialized
    // false.  This test fails before the fix (exception propagates) and passes
    // after it (exception is swallowed).
    await expectLater(initNotifications(), completes);
  });

  test('showNewMailNotification completes without throwing', () async {
    // Platform.isAndroid is false in tests, so this returns early without
    // touching the plugin.  Ensures the guard path is exercised.
    await expectLater(showNewMailNotification('test@example.com'), completes);
  });
}
