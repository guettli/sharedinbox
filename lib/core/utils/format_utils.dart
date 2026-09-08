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
