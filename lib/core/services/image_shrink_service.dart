import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Adjustable knobs for [ImageShrinkService.shrink].
///
/// [defaults] holds the "sane defaults" the shrink dialog seeds from; the user
/// can tweak them and the caller re-runs [ImageShrinkService.shrink].
@immutable
class ImageShrinkSettings {
  const ImageShrinkSettings({
    this.maxDimension = 1600,
    this.jpegQuality = 85,
    this.maxColors = 0,
  });

  /// Longest edge (px) the output is clamped to. Images already smaller are
  /// never upscaled.
  final int maxDimension;

  /// JPEG encoder quality (1–100). Lower means a smaller file.
  final int jpegQuality;

  /// When > 0, the palette is reduced to this many colours before encoding
  /// (0 disables colour reduction).
  final int maxColors;

  static const defaults = ImageShrinkSettings();

  ImageShrinkSettings copyWith({
    int? maxDimension,
    int? jpegQuality,
    int? maxColors,
  }) {
    return ImageShrinkSettings(
      maxDimension: maxDimension ?? this.maxDimension,
      jpegQuality: jpegQuality ?? this.jpegQuality,
      maxColors: maxColors ?? this.maxColors,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImageShrinkSettings &&
        other.maxDimension == maxDimension &&
        other.jpegQuality == jpegQuality &&
        other.maxColors == maxColors;
  }

  @override
  int get hashCode => Object.hash(maxDimension, jpegQuality, maxColors);
}

/// Pixel dimensions and byte size of a source image, reported by
/// [ImageShrinkService.probe] so the dialog can show the original size.
@immutable
class ImageProbe {
  const ImageProbe({
    required this.width,
    required this.height,
    required this.sizeBytes,
  });

  final int width;
  final int height;
  final int sizeBytes;
}

/// Decodes, resizes and re-encodes images so attachments can be shrunk before
/// sending. Pure Dart (package:image) so it works on every target, including
/// Linux/Windows/macOS desktop where native compressors are unavailable.
///
/// The heavy decode/encode work runs in a background isolate via [compute] to
/// keep the UI responsive.
class ImageShrinkService {
  const ImageShrinkService();

  /// Whether an attachment [contentType] names a raster image this service can
  /// re-encode. Everything else is attached unchanged.
  bool isShrinkable(String contentType) {
    final type = contentType.split(';').first.trim().toLowerCase();
    switch (type) {
      case 'image/jpeg':
      case 'image/jpg':
      case 'image/png':
      case 'image/webp':
      case 'image/bmp':
      case 'image/gif':
        return true;
      default:
        return false;
    }
  }

  /// Decodes [path] far enough to report its pixel dimensions and byte size, or
  /// `null` when the file is missing or not a decodable raster image.
  Future<ImageProbe?> probe(String path) => compute(_probeImage, path);

  /// Resizes [path] so its longest edge is at most [ImageShrinkSettings.maxDimension]
  /// (never upscaling), optionally reduces the palette, and re-encodes the
  /// result as JPEG. Returns the encoded bytes, or `null` when the file cannot
  /// be decoded.
  Future<Uint8List?> shrink(String path, ImageShrinkSettings settings) {
    return compute(_shrinkImage, _ShrinkRequest(path, settings));
  }
}

class _ShrinkRequest {
  const _ShrinkRequest(this.path, this.settings);

  final String path;
  final ImageShrinkSettings settings;
}

/// Runs in a background isolate — must be a top-level function.
ImageProbe? _probeImage(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  // decodeImage can throw on malformed/partial data, not just return null.
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  return ImageProbe(
    width: image.width,
    height: image.height,
    sizeBytes: bytes.length,
  );
}

/// Runs in a background isolate — must be a top-level function.
Uint8List? _shrinkImage(_ShrinkRequest request) {
  final file = File(request.path);
  if (!file.existsSync()) return null;
  img.Image? image;
  try {
    image = img.decodeImage(file.readAsBytesSync());
  } catch (_) {
    return null;
  }
  if (image == null) return null;

  final settings = request.settings;
  final longestEdge = image.width > image.height ? image.width : image.height;
  if (longestEdge > settings.maxDimension) {
    // copyResize keeps the aspect ratio when only one edge is given, so clamp
    // whichever edge is longer.
    image = image.width >= image.height
        ? img.copyResize(image, width: settings.maxDimension)
        : img.copyResize(image, height: settings.maxDimension);
  }
  if (settings.maxColors > 0) {
    image = img.quantize(image, numberOfColors: settings.maxColors);
  }
  return img.encodeJpg(image, quality: settings.jpegQuality);
}
