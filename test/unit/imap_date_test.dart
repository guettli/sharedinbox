import 'package:sharedinbox/core/utils/imap_date.dart';
import 'package:test/test.dart';

void main() {
  group('parseImapDateTime', () {
    test('parses the RFC 3501 example and normalises to UTC', () {
      expect(
        parseImapDateTime('17-Jul-1996 02:44:25 -0700'),
        DateTime.utc(1996, 7, 17, 9, 44, 25),
      );
    });

    test('applies a positive offset', () {
      expect(
        parseImapDateTime('15-Oct-2026 14:22:10 +0200'),
        DateTime.utc(2026, 10, 15, 12, 22, 10),
      );
    });

    test('accepts a space-padded day, surrounding quotes and any case', () {
      expect(
        parseImapDateTime('" 5-OCT-2026 12:00:00 +0000"'),
        DateTime.utc(2026, 10, 5, 12),
      );
    });

    test('returns null for null or malformed input', () {
      expect(parseImapDateTime(null), isNull);
      expect(parseImapDateTime(''), isNull);
      expect(parseImapDateTime('Thu, 15 Oct 2026 12:22:10 +0000'), isNull);
      expect(parseImapDateTime('15-Foo-2026 12:22:10 +0000'), isNull);
    });
  });
}
