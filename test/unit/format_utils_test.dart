import 'dart:typed_data';

import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> head, {int pad = 0}) =>
    Uint8List.fromList([...head, ...List<int>.filled(pad, 0)]);

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

  group('sniffImageFormat', () {
    test('detects the formats Flutter can decode by their magic numbers', () {
      expect(
        sniffImageFormat(
          _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], pad: 8),
        ),
        'image/png',
      );
      expect(sniffImageFormat(_bytes([0xFF, 0xD8, 0xFF], pad: 8)), 'image/jpeg');
      // "GIF89a"
      expect(
        sniffImageFormat(_bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        'image/gif',
      );
      // "BM"
      expect(sniffImageFormat(_bytes([0x42, 0x4D], pad: 8)), 'image/bmp');
      // "RIFF" <4 bytes> "WEBP"
      expect(
        sniffImageFormat(
          _bytes([
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x00, 0x00, 0x00, 0x00, // size
            0x57, 0x45, 0x42, 0x50, // WEBP
          ]),
        ),
        'image/webp',
      );
    });

    test('rejects formats Flutter cannot decode', () {
      // AVIF / HEIC: ftyp box (…ftypavif / …ftypheic)
      expect(
        sniffImageFormat(
          _bytes([
            0x00, 0x00, 0x00, 0x1C, //
            0x66, 0x74, 0x79, 0x70, // ftyp
            0x61, 0x76, 0x69, 0x66, // avif
          ]),
        ),
        isNull,
      );
      // SVG (text) and other non-image bytes.
      expect(sniffImageFormat(_bytes([0x3C, 0x3F, 0x78, 0x6D, 0x6C])), isNull);
      expect(sniffImageFormat(_bytes([0x00, 0x01, 0x02, 0x03])), isNull);
    });

    test('rejects empty and truncated headers', () {
      expect(sniffImageFormat(Uint8List(0)), isNull);
      // A lone RIFF with no WEBP tag (e.g. a WAV) must not be treated as WebP.
      expect(sniffImageFormat(_bytes([0x52, 0x49, 0x46, 0x46])), isNull);
      // Truncated PNG signature.
      expect(sniffImageFormat(_bytes([0x89, 0x50])), isNull);
    });
  });
}
