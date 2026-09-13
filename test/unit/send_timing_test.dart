import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/send_timing.dart';

void main() {
  group('formatSendDuration', () {
    test('sub-second durations render in milliseconds', () {
      expect(formatSendDuration(const Duration(milliseconds: 340)), '340ms');
      expect(formatSendDuration(Duration.zero), '0ms');
      expect(formatSendDuration(const Duration(milliseconds: 999)), '999ms');
    });

    test('second-scale durations render with one decimal', () {
      expect(formatSendDuration(const Duration(milliseconds: 1000)), '1.0s');
      expect(formatSendDuration(const Duration(milliseconds: 3140)), '3.1s');
      expect(formatSendDuration(const Duration(seconds: 45)), '45.0s');
    });

    test('minute-scale durations render as Xm Ys', () {
      expect(
        formatSendDuration(const Duration(minutes: 4, seconds: 12)),
        '4m 12s',
      );
      expect(formatSendDuration(const Duration(minutes: 1)), '1m 0s');
      expect(
        formatSendDuration(const Duration(minutes: 25, seconds: 3)),
        '25m 3s',
      );
    });
  });

  group('SendTiming', () {
    test('summary reports queue wait, total, and each phase in order', () {
      final timing = SendTiming(
        queuedFor: const Duration(minutes: 4, seconds: 12),
      )
        ..record('SMTP connect/auth', const Duration(milliseconds: 1100))
        ..record('SMTP send message', const Duration(milliseconds: 400))
        ..total = const Duration(milliseconds: 1500);

      expect(
        timing.summary,
        'queued 4m 12s, sent in 1.5s '
        '(SMTP connect/auth 1.1s, SMTP send message 400ms)',
      );
    });

    test('summary omits the phase list when no phases were recorded', () {
      final timing = SendTiming(queuedFor: const Duration(seconds: 2))
        ..total = const Duration(milliseconds: 300);

      expect(timing.summary, 'queued 2.0s, sent in 300ms');
    });

    test('toLogData exposes the numbers as machine-readable milliseconds', () {
      final timing = SendTiming(queuedFor: const Duration(seconds: 90))
        ..record('IMAP connect/login', const Duration(milliseconds: 900))
        ..record(
            'IMAP append to Sent folder', const Duration(milliseconds: 700))
        ..total = const Duration(milliseconds: 1600);

      expect(timing.toLogData(), {
        'queuedForMs': 90000,
        'transmitMs': 1600,
        'phaseMs': {
          'IMAP connect/login': 900,
          'IMAP append to Sent folder': 700,
        },
      });
    });
  });
}
