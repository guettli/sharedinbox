import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/services/connectivity_service.dart';

/// Fake clock that lets tests move time forward deterministically. Used to
/// exercise the debounce window in [ConnectivityService] without waiting.
class _FakeClock {
  DateTime _now = DateTime(2026, 1, 1, 12);

  DateTime call() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectivityService', () {
    test('initialize completes without throwing when plugin is unavailable',
        () async {
      final svc = ConnectivityService();
      await expectLater(svc.initialize(), completes);
      svc.dispose();
    });

    test('emits once on offline → online transition', () async {
      final clock = _FakeClock();
      final svc = ConnectivityService(
        initialOnline: false,
        clock: clock.call,
      );
      final events = <void>[];
      final sub = svc.onOnline.listen(events.add);

      svc.notify(online: true);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));

      await sub.cancel();
      svc.dispose();
    });

    test('does not emit when already online', () async {
      final clock = _FakeClock();
      final svc = ConnectivityService(clock: clock.call);
      final events = <void>[];
      final sub = svc.onOnline.listen(events.add);

      svc.notify(online: true);
      svc.notify(online: true);
      await Future<void>.delayed(Duration.zero);

      expect(
        events,
        isEmpty,
        reason: 'a stream of online events without an intervening offline '
            'must not trigger a reconnect kick',
      );

      await sub.cancel();
      svc.dispose();
    });

    test('does not emit on offline transitions', () async {
      final clock = _FakeClock();
      final svc = ConnectivityService(clock: clock.call);
      final events = <void>[];
      final sub = svc.onOnline.listen(events.add);

      svc.notify(online: false);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);

      await sub.cancel();
      svc.dispose();
    });

    test('debounces bursts of offline↔online transitions', () async {
      final clock = _FakeClock();
      final svc = ConnectivityService(
        initialOnline: false,
        clock: clock.call,
      );
      final events = <void>[];
      final sub = svc.onOnline.listen(events.add);

      // First reconnect at t=0 emits.
      svc.notify(online: true);
      // A quick flap (offline then online again 500ms later) must not emit.
      clock.advance(const Duration(milliseconds: 500));
      svc.notify(online: false);
      svc.notify(online: true);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));

      // After the debounce window has elapsed, another reconnect emits again.
      clock.advance(const Duration(seconds: 3));
      svc.notify(online: false);
      svc.notify(online: true);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));

      await sub.cancel();
      svc.dispose();
    });

    test('emits again after subsequent offline → online transitions', () async {
      final clock = _FakeClock();
      final svc = ConnectivityService(
        initialOnline: false,
        clock: clock.call,
      );
      final events = <void>[];
      final sub = svc.onOnline.listen(events.add);

      svc.notify(online: true);
      clock.advance(const Duration(seconds: 10));
      svc.notify(online: false);
      clock.advance(const Duration(seconds: 10));
      svc.notify(online: true);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));

      await sub.cancel();
      svc.dispose();
    });
  });
}
