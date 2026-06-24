import 'package:sharedinbox/core/utils/received_header.dart';
import 'package:test/test.dart';

void main() {
  group('parseReceivedTimestamp', () {
    test('parses UTC offset to UTC instant', () {
      final ts = parseReceivedTimestamp(
        'by mx.example.com; Mon, 1 Jan 2024 12:00:00 +0000 (UTC)',
      );
      expect(ts, isNotNull);
      expect(ts!.isUtc, isTrue);
      expect(ts, DateTime.utc(2024, 1, 1, 12));
    });

    test('applies positive offset when normalising to UTC', () {
      // 12:00 in +0530 is 06:30 UTC.
      final ts = parseReceivedTimestamp(
        'by mx.example.com; Mon, 1 Jan 2024 12:00:00 +0530 (IST)',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 6, 30));
    });

    test('applies negative offset when normalising to UTC', () {
      // 12:00 in -0500 is 17:00 UTC.
      final ts = parseReceivedTimestamp(
        'by mx.example.com; Mon, 1 Jan 2024 12:00:00 -0500',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 17));
    });

    test('duration between hops respects differing time zones', () {
      // Same instant expressed in two zones — delay must be zero.
      final earlier = parseReceivedTimestamp(
        'by a; Mon, 1 Jan 2024 12:00:00 +0000',
      )!;
      final later = parseReceivedTimestamp(
        'by b; Mon, 1 Jan 2024 07:00:00 -0500',
      )!;
      expect(later.difference(earlier), Duration.zero);
    });

    test('two-second hop across zones reports two seconds', () {
      // First server (CET +0100) hands off at 13:00:00; receiving server
      // (UTC +0000) records the next hop at 12:00:02 — a two-second delay.
      final first = parseReceivedTimestamp(
        'by a; Mon, 1 Jan 2024 13:00:00 +0100',
      )!;
      final second = parseReceivedTimestamp(
        'by b; Mon, 1 Jan 2024 12:00:02 +0000',
      )!;
      expect(second.difference(first), const Duration(seconds: 2));
    });

    test('parses two-digit day without leading zero', () {
      final ts = parseReceivedTimestamp(
        'by mx; Wed, 24 Jun 2026 08:15:30 +0200',
      );
      expect(ts, DateTime.utc(2026, 6, 24, 6, 15, 30));
    });

    test('parses without day-of-week prefix', () {
      final ts = parseReceivedTimestamp(
        'by mx; 1 Jan 2024 12:00:00 +0000',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 12));
    });

    test('parses obsolete named zone GMT as UTC', () {
      final ts = parseReceivedTimestamp(
        'by mx; Mon, 1 Jan 2024 12:00:00 GMT',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 12));
    });

    test('parses obsolete named zone EST', () {
      final ts = parseReceivedTimestamp(
        'by mx; Mon, 1 Jan 2024 12:00:00 EST',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 17));
    });

    test('omitted offset is treated as UTC', () {
      final ts = parseReceivedTimestamp('by mx; 1 Jan 2024 12:00:00');
      expect(ts, DateTime.utc(2024, 1, 1, 12));
    });

    test('returns null when no date follows the semicolon', () {
      expect(parseReceivedTimestamp('by mx.example.com'), isNull);
    });

    test('returns null on unparseable date', () {
      expect(
        parseReceivedTimestamp('by mx; not a date at all'),
        isNull,
      );
    });

    test('uses last semicolon when value contains multiple', () {
      final ts = parseReceivedTimestamp(
        'from a; by b; Mon, 1 Jan 2024 12:00:00 +0000',
      );
      expect(ts, DateTime.utc(2024, 1, 1, 12));
    });
  });
}
