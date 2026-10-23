import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sync/log_retention_scheduler.dart';

void main() {
  // LogRetentionScheduler's default interval.
  const interval = Duration(hours: 6);

  test('trims at start and again after every interval', () {
    fakeAsync((async) {
      var trims = 0;
      final scheduler = LogRetentionScheduler(
        trim: () async => trims++,
      )..start();
      async.flushMicrotasks();
      expect(trims, 1);

      async.elapse(interval - const Duration(minutes: 1));
      expect(trims, 1);
      async.elapse(const Duration(minutes: 1));
      expect(trims, 2);
      async.elapse(interval);
      expect(trims, 3);

      // A second start() neither trims again nor adds a schedule.
      scheduler.start();
      async.elapse(interval);
      expect(trims, 4);
      scheduler.dispose();
    });
  });

  test('dispose cancels the periodic trim', () {
    fakeAsync((async) {
      var trims = 0;
      final scheduler = LogRetentionScheduler(
        trim: () async => trims++,
      )..start();
      async.flushMicrotasks();
      scheduler.dispose();
      expect(scheduler.isScheduled, isFalse);
      async.elapse(interval * 3);
      expect(trims, 1);
    });
  });

  test('a tick during a running trim is skipped', () {
    fakeAsync((async) {
      var trims = 0;
      final gate = Completer<void>();
      final scheduler = LogRetentionScheduler(
        trim: () {
          trims++;
          return gate.future;
        },
      )..start();
      async.elapse(interval * 2);
      expect(trims, 1);
      gate.complete();
      async.elapse(interval);
      expect(trims, 2);
      scheduler.dispose();
    });
  });

  test('a failing trim (e.g. closed database) keeps the schedule', () {
    fakeAsync((async) {
      var trims = 0;
      final scheduler = LogRetentionScheduler(
        trim: () async {
          trims++;
          throw StateError('database closed');
        },
      )..start();
      async.elapse(interval);
      expect(trims, 2);
      expect(scheduler.isScheduled, isTrue);
      scheduler.dispose();
    });
  });
}
