import 'package:sharedinbox/core/services/report_limits.dart';
import 'package:test/test.dart';

void main() {
  group('truncateReportField', () {
    test('leaves a field within the cap untouched', () {
      expect(truncateReportField('short', 10), 'short');
      expect(truncateReportField('x' * 10, 10), 'x' * 10);
    });

    test('cuts an over-long field to exactly the cap, marker included', () {
      final out = truncateReportField('x' * 50, 20);
      expect(out.runes.length, 20);
      expect(out, endsWith(reportTruncationMarker));
      expect(out, startsWith('x' * (20 - reportTruncationMarker.runes.length)));
    });

    test('counts runes, never splitting a surrogate pair', () {
      final out = truncateReportField('😀' * 30, 20);
      expect(out.runes.length, 20);
      final kept = '😀' * (20 - reportTruncationMarker.runes.length);
      expect(out, kept + reportTruncationMarker);
    });

    test('is idempotent, so the server never cuts an app report again', () {
      final once = truncateReportField('y' * 9000, reportDescriptionMaxRunes);
      expect(truncateReportField(once, reportDescriptionMaxRunes), once);
    });
  });
}
