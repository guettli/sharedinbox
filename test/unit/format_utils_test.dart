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

  group('isDisplayableImage', () {
    test('accepts formats Flutter can decode natively', () {
      expect(isDisplayableImage('image/png'), isTrue);
      expect(isDisplayableImage('image/jpeg'), isTrue);
      expect(isDisplayableImage('image/jpg'), isTrue);
      expect(isDisplayableImage('image/gif'), isTrue);
      expect(isDisplayableImage('image/webp'), isTrue);
      expect(isDisplayableImage('image/bmp'), isTrue);
    });

    test('is case-insensitive and tolerates MIME parameters', () {
      expect(isDisplayableImage('IMAGE/PNG'), isTrue);
      expect(isDisplayableImage('image/jpeg; name=photo.jpg'), isTrue);
      expect(isDisplayableImage('  image/png  '), isTrue);
    });

    test('rejects image formats Flutter cannot decode', () {
      expect(isDisplayableImage('image/avif'), isFalse);
      expect(isDisplayableImage('image/heic'), isFalse);
      expect(isDisplayableImage('image/heif'), isFalse);
    });

    test('rejects non-image content types', () {
      expect(isDisplayableImage('application/pdf'), isFalse);
      expect(isDisplayableImage('text/plain'), isFalse);
      expect(isDisplayableImage(''), isFalse);
    });
  });
}
