import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

// Fake PathProviderPlatform that fails the first [failCount] calls, then
// returns a fixed path.  Used to exercise the retry loop in
// _resolveDatabasePath() without waiting for real timers.
class _SucceedAfterNPathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _SucceedAfterNPathProvider({required this.failCount});

  final int failCount;
  int _callCount = 0;

  @override
  Future<String?> getApplicationSupportPath() async {
    _callCount++;
    if (_callCount <= failCount) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Simulated: path_provider channel not ready',
      );
    }
    return '/tmp/test_app_support';
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

  // Tests for _resolveDatabasePath() — the lazy retry path called on first DB
  // access when initDatabasePath() already failed.  fake_async lets us advance
  // the back-off timers without waiting real-world milliseconds.

  test(
    '_resolveDatabasePath retries and eventually succeeds after transient failures',
    () {
      resetDatabasePathForTesting();
      final prev = PathProviderPlatform.instance;
      // Fail 3 times, succeed on the 4th call.  The delays in
      // _resolveDatabasePath are [200, 500, 1000, 2000, 4000] ms, so three
      // failures cost 200+500+1000 = 1700 ms before the fourth attempt.
      PathProviderPlatform.instance = _SucceedAfterNPathProvider(failCount: 3);
      addTearDown(() {
        PathProviderPlatform.instance = prev;
        resetDatabasePathForTesting();
      });

      fakeAsync((fake) {
        String? result;
        unawaited(resolveDatabasePathForTesting().then((r) => result = r));

        // Advance fake time through the three back-off delays.
        fake.elapse(const Duration(milliseconds: 200 + 500 + 1000 + 1));

        expect(result, isNotNull);
        expect(result, endsWith('sharedinbox.db'));
      });
    },
  );

  test(
    '_resolveDatabasePath throws PlatformException after exhausting all retries',
    () {
      resetDatabasePathForTesting();
      final prev = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _UnavailablePathProvider();
      addTearDown(() {
        PathProviderPlatform.instance = prev;
        resetDatabasePathForTesting();
      });

      fakeAsync((fake) {
        Object? caughtError;
        unawaited(
          resolveDatabasePathForTesting().catchError((Object e) {
            caughtError = e;
            return ''; // ignored; satisfies the Future<String> return type
          }),
        );

        // Advance past all five back-off delays: 200+500+1000+2000+4000 ms.
        fake.elapse(
          const Duration(milliseconds: 200 + 500 + 1000 + 2000 + 4000 + 1),
        );

        expect(caughtError, isA<PlatformException>());
        expect(
          (caughtError! as PlatformException).message,
          contains('cannot open database'),
        );
      });
    },
  );
}
