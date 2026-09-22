import 'dart:typed_data';

/// Returns a human-readable file size string (B / KB / MB / GB).
String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Whether an attachment [contentType] names an image format that Flutter's
/// built-in decoder can render inline (PNG, JPEG, GIF, WebP, BMP).
///
/// Formats Flutter cannot decode natively — notably AVIF and HEIC/HEIF — return
/// `false` so the caller can fall back to the download-and-open flow instead of
/// showing a broken preview. The match is case-insensitive and tolerates MIME
/// parameters (e.g. `image/png; name=foo.png`).
bool isDisplayableImage(String contentType) {
  final type = contentType.split(';').first.trim().toLowerCase();
  switch (type) {
    case 'image/png':
    case 'image/jpeg':
    case 'image/jpg':
    case 'image/gif':
    case 'image/webp':
    case 'image/bmp':
      return true;
    default:
      return false;
  }
}

/// Sniffs the magic-number signature at the start of [bytes] and returns the
/// canonical MIME type of the raster format it detects, or `null` when the
/// bytes are empty, truncated, or don't match any format Flutter's built-in
/// decoder can render (PNG, JPEG, GIF, WebP, BMP).
///
/// The declared MIME type alone cannot be trusted: a part labelled `image/jpeg`
/// may actually contain AVIF/HEIC/SVG bytes, or even the raw bytes of a whole
/// multipart message. Feeding those to [Image] does not throw — the decoder
/// either mis-decodes them into a rectangle of colour-noise or produces nothing
/// at all, and [Image]'s `errorBuilder` never fires for the noise case (#830).
/// Callers use this to verify that the *decoded* bytes really are a displayable
/// image before showing them inline.
String? sniffImageFormat(Uint8List bytes) {
  bool matches(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (matches(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  // JPEG: FF D8 FF
  if (matches(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  // GIF: "GIF8" (covers both GIF87a and GIF89a)
  if (matches(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  // BMP: "BM"
  if (matches(const [0x42, 0x4D])) return 'image/bmp';
  // WebP: "RIFF" <4-byte size> "WEBP"
  if (matches(const [0x52, 0x49, 0x46, 0x46]) &&
      matches(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
