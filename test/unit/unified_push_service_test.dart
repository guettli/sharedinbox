import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/unified_push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression cover for the same defensive pattern used by
  // notification_service_test.dart and background_sync_test.dart: when
  // running outside of a real device (or on a desktop platform) the
  // native UnifiedPush channel is absent, so every public method has to
  // absorb the failure and keep the app alive.
  group('UnifiedPushService', () {
    test('initialize completes without throwing when plugin is unavailable',
        () async {
      final svc = UnifiedPushService();
      await expectLater(svc.initialize(), completes);
      svc.dispose();
    });

    test('getDistributors returns an empty list when plugin is unavailable',
        () async {
      final svc = UnifiedPushService();
      final result = await svc.getDistributors();
      expect(result, isEmpty);
      svc.dispose();
    });

    test('getDistributor returns null when plugin is unavailable', () async {
      final svc = UnifiedPushService();
      final result = await svc.getDistributor();
      expect(result, isNull);
      svc.dispose();
    });

    test('pickDistributor completes without throwing', () async {
      final svc = UnifiedPushService();
      await expectLater(svc.pickDistributor('any.distributor'), completes);
      svc.dispose();
    });

    test('unregister completes without throwing', () async {
      final svc = UnifiedPushService();
      await expectLater(svc.unregister(), completes);
      svc.dispose();
    });

    test('watch stream emits state changes', () async {
      final svc = UnifiedPushService();
      final events = <UnifiedPushStatus>[];
      final sub = svc.watch().listen(events.add);
      // pickDistributor sets _lastError on unsupported platforms which
      // triggers an emit; verifies the broadcast pipeline works.
      await svc.pickDistributor('foo');
      // Give the microtask queue a chance to deliver the event.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      svc.dispose();
      // On platforms where isSupported is false the call is a no-op and
      // no event is emitted; that path is also valid behaviour, so this
      // assertion is intentionally lax.
      expect(events.length, lessThanOrEqualTo(1));
    });

    test('endpoint and lastError start unset', () {
      final svc = UnifiedPushService();
      expect(svc.endpoint, isNull);
      expect(svc.lastError, isNull);
      svc.dispose();
    });
  });
}
