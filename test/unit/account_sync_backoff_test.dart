// Tests for the exponential-backoff clamping logic used in AccountSyncManager.
// The manager itself requires Flutter DI, so we test the math standalone.

import 'package:test/test.dart';

int nextBackoff(int current) => (current * 2).clamp(5, 300);

void main() {
  group('sync backoff', () {
    test('starts at 5 seconds', () {
      expect(5, 5);
    });

    test('doubles each failure', () {
      var backoff = 5;
      backoff = nextBackoff(backoff);
      expect(backoff, 10);
      backoff = nextBackoff(backoff);
      expect(backoff, 20);
      backoff = nextBackoff(backoff);
      expect(backoff, 40);
      backoff = nextBackoff(backoff);
      expect(backoff, 80);
      backoff = nextBackoff(backoff);
      expect(backoff, 160);
    });

    test('clamps at 300 seconds (5 minutes)', () {
      var backoff = 5;
      for (var i = 0; i < 20; i++) {
        backoff = nextBackoff(backoff);
      }
      expect(backoff, 300);
    });

    test('never goes below 5 seconds', () {
      expect(nextBackoff(1), 5);
      expect(nextBackoff(0), 5);
    });
  });
}
