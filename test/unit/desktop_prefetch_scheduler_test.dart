import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/sync/desktop_prefetch_scheduler.dart';

void main() {
  late StreamController<PrefetchMode> modes;
  late int runs;
  DesktopPrefetchScheduler? scheduler;

  DesktopPrefetchScheduler build({
    Future<void> Function()? runPrefetch,
  }) =>
      DesktopPrefetchScheduler(
        modes: modes.stream,
        runPrefetch: runPrefetch ??
            () async {
              runs++;
            },
      );

  setUp(() {
    modes = StreamController<PrefetchMode>();
    runs = 0;
  });

  tearDown(() {
    scheduler?.dispose();
    scheduler = null;
    unawaited(modes.close());
  });

  for (final mode in [PrefetchMode.wifiOnly, PrefetchMode.always]) {
    test('runs after the initial delay and then hourly for ${mode.name}', () {
      fakeAsync((async) {
        scheduler = build()..start();
        modes.add(mode);
        async.elapse(const Duration(seconds: 59));
        expect(runs, 0);
        async.elapse(const Duration(seconds: 1));
        expect(runs, 1);
        async.elapse(const Duration(minutes: 59));
        expect(runs, 1);
        async.elapse(const Duration(minutes: 1));
        expect(runs, 2);
        async.elapse(const Duration(hours: 3));
        expect(runs, 5);
      });
    });
  }

  test('never runs while disabled', () {
    fakeAsync((async) {
      scheduler = build()..start();
      modes.add(PrefetchMode.disabled);
      async.elapse(const Duration(hours: 5));
      expect(runs, 0);
      expect(scheduler!.isScheduled, isFalse);
    });
  });

  test('switching to disabled cancels, re-enabling reschedules', () {
    fakeAsync((async) {
      scheduler = build()..start();
      modes.add(PrefetchMode.wifiOnly);
      async.elapse(const Duration(minutes: 1));
      expect(runs, 1);

      modes.add(PrefetchMode.disabled);
      async.elapse(const Duration(hours: 3));
      expect(runs, 1);
      expect(scheduler!.isScheduled, isFalse);

      modes.add(PrefetchMode.always);
      async.elapse(const Duration(minutes: 1));
      expect(runs, 2);
      expect(scheduler!.isScheduled, isTrue);
    });
  });

  test('switching between wifiOnly and always keeps the schedule', () {
    fakeAsync((async) {
      scheduler = build()..start();
      modes.add(PrefetchMode.wifiOnly);
      async.elapse(const Duration(minutes: 30));
      modes.add(PrefetchMode.always);
      async.elapse(const Duration(minutes: 30));
      // Not pushed back by the mode switch.
      expect(runs, 1);
    });
  });

  test('runs never overlap; a tick during a slow run is skipped', () {
    fakeAsync((async) {
      var started = 0;
      final pending = <Completer<void>>[];
      scheduler = build(
        runPrefetch: () {
          started++;
          final c = Completer<void>();
          pending.add(c);
          return c.future;
        },
      )..start();
      modes.add(PrefetchMode.wifiOnly);
      async.elapse(const Duration(minutes: 1));
      expect(started, 1);
      // The first run is still going when the next hourly tick fires.
      async.elapse(const Duration(hours: 1));
      expect(started, 1);
      pending.first.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(hours: 1));
      expect(started, 2);
      pending.last.complete();
      async.flushMicrotasks();
    });
  });

  test('a failing run does not stop the schedule', () {
    fakeAsync((async) {
      scheduler = build(
        runPrefetch: () async {
          runs++;
          throw StateError('IMAP down');
        },
      )..start();
      modes.add(PrefetchMode.always);
      async.elapse(const Duration(hours: 2, minutes: 1));
      expect(runs, 3);
    });
  });

  test('dispose stops the schedule', () {
    fakeAsync((async) {
      scheduler = build()..start();
      modes.add(PrefetchMode.always);
      scheduler!.dispose();
      async.elapse(const Duration(hours: 2));
      expect(runs, 0);
    });
  });

  test('in-process prefetch is needed on desktop only', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final desktop = platform == TargetPlatform.linux ||
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows;
      expect(needsInProcessBodyPrefetch, desktop, reason: platform.name);
    }
  });

  test('an error on the preference stream does not stop the schedule', () {
    fakeAsync((async) {
      scheduler = build()..start();
      modes.addError(StateError('db closed'));
      modes.add(PrefetchMode.always);
      async.elapse(const Duration(minutes: 1));
      expect(runs, 1);
    });
  });
}
