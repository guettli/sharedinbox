// Regression test for #355:
// A SocketException fired inside the JMAP sync loop (device offline)
// escaped to `runZonedGuarded → FlutterError.reportError → FlutterError.onError`
// and replaced the whole app with the CrashScreen. Going offline is a normal
// state on mobile — the sync loop already retries — so the top-level handler
// in main.dart now short-circuits for transient network errors instead of
// tearing the app down.

import 'dart:async';
import 'dart:io';

import 'package:sharedinbox/main.dart' show isTransientNetworkError;
import 'package:test/test.dart';

void main() {
  group('isTransientNetworkError', () {
    test('SocketException from a cancelled connect attempt is transient', () {
      // Same shape as the crash reported in #355:
      //   SocketException: Connection attempt cancelled,
      //     host: mail.thomas-guettler.de, port: 443
      const error = SocketException(
        'Connection attempt cancelled',
        osError: OSError('Connection attempt cancelled', 0),
      );
      expect(isTransientNetworkError(error), isTrue);
    });

    test('HttpException is transient', () {
      expect(isTransientNetworkError(const HttpException('boom')), isTrue);
    });

    test('HandshakeException is transient', () {
      expect(
        isTransientNetworkError(const HandshakeException('handshake failed')),
        isTrue,
      );
    });

    test('TimeoutException is transient', () {
      expect(
        isTransientNetworkError(TimeoutException('too slow')),
        isTrue,
      );
    });

    test('unrelated exceptions are not transient', () {
      expect(isTransientNetworkError(StateError('bad state')), isFalse);
      expect(isTransientNetworkError(ArgumentError('bad arg')), isFalse);
      expect(isTransientNetworkError(Exception('generic')), isFalse);
      expect(isTransientNetworkError('a string error'), isFalse);
    });
  });
}
