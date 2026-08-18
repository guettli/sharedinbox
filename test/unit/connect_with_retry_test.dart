// Regression test for #609:
// A transient DNS hiccup on mobile (`SocketException: Failed host lookup:
// 'imap.gmail.com' ... errno = 7`) surfaced as a failed Sync Entry even though
// the device's connection was fine. connectImap/connectSmtp now retry a bounded
// number of times for transient socket/DNS errors so a brief hiccup no longer
// produces a spurious failure. Permanent errors (TLS/auth) still fail fast.

import 'dart:async';
import 'dart:io';

import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show connectWithRetry;
import 'package:test/test.dart';

void main() {
  group('connectWithRetry', () {
    test('does not retry when the first attempt succeeds', () async {
      var calls = 0;
      await connectWithRetry(() async => calls++);
      expect(calls, 1);
    });

    test('retries a transient SocketException, then succeeds', () async {
      var calls = 0;
      await connectWithRetry(() async {
        calls++;
        if (calls < 2) {
          throw const SocketException('Failed host lookup: imap.gmail.com');
        }
      });
      expect(calls, 2);
    });

    test('gives up and rethrows after exhausting retries', () async {
      var calls = 0;
      await expectLater(
        connectWithRetry(() async {
          calls++;
          throw const SocketException('Failed host lookup: imap.gmail.com');
        }),
        throwsA(isA<SocketException>()),
      );
      // Initial attempt + two retries.
      expect(calls, 3);
    });

    test('retries a TimeoutException', () async {
      var calls = 0;
      await connectWithRetry(() async {
        calls++;
        if (calls < 2) throw TimeoutException('too slow');
      });
      expect(calls, 2);
    });

    test('does not retry a non-transient error', () async {
      var calls = 0;
      await expectLater(
        connectWithRetry(() async {
          calls++;
          throw StateError('permanent');
        }),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
    });
  });
}
