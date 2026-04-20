import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:test/test.dart';

void main() {
  group('fmtSize', () {
    test('formats bytes', () {
      expect(fmtSize(0), '0 B');
      expect(fmtSize(1), '1 B');
      expect(fmtSize(1023), '1023 B');
    });

    test('formats kilobytes', () {
      expect(fmtSize(1024), '1.0 KB');
      expect(fmtSize(1536), '1.5 KB');
      expect(fmtSize(1024 * 1023), '1023.0 KB');
    });

    test('formats megabytes', () {
      expect(fmtSize(1024 * 1024), '1.0 MB');
      expect(fmtSize((1024 * 1024 * 2.5).round()), '2.5 MB');
    });

    test('formats gigabytes', () {
      expect(fmtSize(1024 * 1024 * 1024), '1.0 GB');
    });
  });
}
