import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sync/background_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression test for https://codeberg.org/guettli/sharedinbox/issues/149:
  // On some Android devices the WorkManager platform channel is absent at
  // startup, throwing PlatformException(channel-error, ...).
  // registerBackgroundSync() must absorb the failure and let the app continue.
  test(
    'registerBackgroundSync completes without throwing when plugin is unavailable',
    () async {
      // In the unit-test environment the native WorkManager plugin is not
      // registered, so Workmanager().initialize() throws a PlatformException or
      // MissingPluginException.  The fix catches it.  This test fails before the
      // fix (exception propagates) and passes after it (exception is swallowed).
      await expectLater(registerBackgroundSync(), completes);
    },
  );
}
