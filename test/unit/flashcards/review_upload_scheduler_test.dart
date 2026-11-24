import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/review_upload_scheduler.dart';
import 'package:sharedinbox/core/services/app_logger.dart';

import '../recording_app_log_repository.dart';

void main() {
  late List<String> flushed;
  late Set<String> pending;
  late Completer<void>? gate;
  late RecordingAppLogRepository logs;

  ReviewUploadScheduler scheduler({Object? failWith}) {
    flushed = [];
    pending = {};
    gate = null;
    logs = RecordingAppLogRepository();
    return ReviewUploadScheduler(
      flush: (accountId) async {
        flushed.add(accountId);
        await gate?.future;
        if (failWith != null) throw failWith;
      },
      pendingAccounts: () async => pending,
      appLogger: AppLogger(logs),
    );
  }

  test('a rating flushes after 5 min idle; each rating restarts the idle time',
      () {
    fakeAsync((async) {
      final s = scheduler();
      s.rated('a', 1);
      async.elapse(const Duration(minutes: 4));
      s.rated('a', 2);
      async.elapse(const Duration(minutes: 4, seconds: 59));
      expect(flushed, isEmpty);
      async.elapse(const Duration(seconds: 1));
      // Then debounced.
      expect(flushed, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(flushed, ['a']);
      async.elapse(const Duration(minutes: 10));
      expect(flushed, ['a']);
      s.dispose();
    });
  });

  test('300 pending reviews flush at once', () {
    fakeAsync((async) {
      final s = scheduler();
      s.rated('a', 299);
      async.flushMicrotasks();
      expect(flushed, isEmpty);
      s.rated('a', 300);
      async.flushMicrotasks();
      expect(flushed, ['a']);
      // The idle timer of the account is gone.
      async.elapse(const Duration(minutes: 6));
      expect(flushed, ['a']);
      s.dispose();
    });
  });

  test('session end and a sync cycle are debounced into one flush', () {
    fakeAsync((async) {
      final s = scheduler();
      s.rated('a', 1);
      s.endSession('a');
      async.elapse(const Duration(seconds: 1));
      s.synced('a');
      s.synced('b');
      async.elapse(const Duration(seconds: 1));
      expect(flushed, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(flushed, unorderedEquals(['a', 'b']));
      // The flush took the idle timer of `a` with it.
      async.elapse(const Duration(minutes: 6));
      expect(flushed, hasLength(2));
      s.dispose();
    });
  });

  test('the app going to the background flushes every pending account', () {
    fakeAsync((async) {
      final s = scheduler();
      pending.addAll(['a', 'c']);
      unawaited(s.appPaused());
      async.elapse(const Duration(seconds: 2));
      expect(flushed, unorderedEquals(['a', 'c']));
      s.dispose();
    });
  });

  test('a request while a flush runs gives one more flush after it', () {
    fakeAsync((async) {
      final s = scheduler();
      gate = Completer<void>();
      s.rated('a', 300);
      async.flushMicrotasks();
      expect(flushed, ['a']);
      s.rated('a', 301);
      s.rated('a', 302);
      async.flushMicrotasks();
      expect(flushed, ['a']);
      gate!.complete();
      async.flushMicrotasks();
      expect(flushed, ['a', 'a']);
      s.dispose();
    });
  });

  test('a failed flush is logged; the next trigger tries again', () {
    fakeAsync((async) {
      final s = scheduler(failWith: StateError('locked'));
      s.endSession('a');
      async.elapse(const Duration(seconds: 2));
      expect(flushed, ['a']);
      expect(
        [for (final r in logs.rows) r.event],
        contains('review.upload_failed'),
      );
      s.endSession('a');
      async.elapse(const Duration(seconds: 2));
      expect(flushed, ['a', 'a']);
      s.dispose();
    });
  });

  test('after dispose nothing flushes', () {
    fakeAsync((async) {
      final s = scheduler();
      s.rated('a', 1);
      s.endSession('b');
      s.dispose();
      s.rated('a', 500);
      s.synced('a');
      pending.add('a');
      unawaited(s.appPaused());
      async.elapse(const Duration(minutes: 10));
      expect(flushed, isEmpty);
    });
  });
}
