import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/notification_guard.dart';

void main() {
  // #1107: a notification backend that fails or never answers must not
  // escape to the caller.
  group('guardNotificationShow', () {
    late List<String> warnings;

    setUp(() => warnings = []);

    Future<bool> guard(
      Future<void> Function() show, {
      Duration timeout = const Duration(milliseconds: 50),
    }) =>
        guardNotificationShow(show, timeout: timeout, onWarning: warnings.add);

    test('returns true and warns nothing when the show succeeds', () async {
      expect(await guard(() async {}), isTrue);
      expect(warnings, isEmpty);
    });

    test('swallows an async exception', () async {
      final shown = await guard(() async => throw StateError('no daemon'));
      expect(shown, isFalse);
      expect(warnings.single, contains('no daemon'));
    });

    test('swallows a synchronous throw from the show callback', () async {
      final shown = await guard(() => throw StateError('sync'));
      expect(shown, isFalse);
      expect(warnings.single, contains('sync'));
    });

    test('gives up on a show that never completes', () async {
      final shown = await guard(() => Completer<void>().future);
      expect(shown, isFalse);
      expect(warnings.single, contains('no reply'));
    });
  });
}
