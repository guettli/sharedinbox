import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:sharedinbox/data/db/database.dart';

// Fake PathProviderPlatform that always throws PlatformException(channel-error)
// to simulate the Pigeon channel not being ready at startup (issue #166).
class _UnavailablePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    throw PlatformException(
      code: 'channel-error',
      message: 'Simulated: path_provider channel not ready',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression test for https://codeberg.org/guettli/sharedinbox/issues/166:
  // On some slow Android devices the path_provider Pigeon channel is not ready
  // when initDatabasePath() runs before runApp(). initDatabasePath() must
  // absorb the PlatformException and let the app start; _resolveDatabasePath()
  // then retries with back-off on first DB access.
  test(
    'initDatabasePath completes without throwing when path_provider is unavailable',
    () async {
      final prev = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _UnavailablePathProvider();
      addTearDown(() => PathProviderPlatform.instance = prev);

      // Must not throw — the exception is swallowed so the app can continue.
      await expectLater(initDatabasePath(), completes);
    },
  );
}
