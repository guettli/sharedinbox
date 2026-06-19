// Regression test for https://codeberg.org/guettli/sharedinbox/issues/NNN:
// _registerPrefetchTaskFromStoredPrefs had no try/catch, so any database error
// at startup (e.g. path_provider channel unavailable) propagated to
// FlutterError.onError, which replaced the whole app with a CrashScreen.
//
// The fix wraps the function body in try/catch so all errors are swallowed.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/main.dart';

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

  test(
    'registerPrefetchTaskFromStoredPrefs completes without throwing when DB cannot be opened',
    () {
      resetDatabasePathForTesting();
      final prev = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _UnavailablePathProvider();
      addTearDown(() {
        PathProviderPlatform.instance = prev;
        resetDatabasePathForTesting();
      });

      fakeAsync((fake) {
        bool completed = false;
        unawaited(
          registerPrefetchTaskFromStoredPrefsForTesting()
              .then((_) => completed = true),
        );

        // _resolveDatabasePath() retries with back-off delays totalling 7700 ms
        // before throwing. Advance time so the retries complete.
        fake.elapse(const Duration(milliseconds: 8000));

        expect(completed, isTrue, reason: 'function must complete, not hang');
      });
    },
  );
}
