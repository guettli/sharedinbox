import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/logger.dart';

void main() {
  // Suppress debugPrint so log() calls don't produce noisy output in test runs.
  late DebugPrintCallback savedDebugPrint;
  setUp(() {
    savedDebugPrint = debugPrint;
    debugPrint = (_, {wrapWidth}) {};
  });
  tearDown(() => debugPrint = savedDebugPrint);

  group('log', () {
    test('logs a plain message without throwing', () {
      expect(() => log('hello from test'), returnsNormally);
    });

    test('logs a message with an error without throwing', () {
      expect(
        () => log('something went wrong', error: Exception('boom')),
        returnsNormally,
      );
    });

    test('logs a message with error and stack trace without throwing', () {
      final stack = StackTrace.current;
      expect(
        () => log('oops', error: Exception('x'), stackTrace: stack),
        returnsNormally,
      );
    });
  });
}
