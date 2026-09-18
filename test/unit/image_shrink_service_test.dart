import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:sharedinbox/core/services/image_shrink_service.dart';

void main() {
  const service = ImageShrinkService();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shrink_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<String> writePng(int width, int height) async {
    final image = img.Image(width: width, height: height);
    // A gradient gives the JPEG encoder real detail to work with, so quality
    // changes actually move the byte count.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
      }
    }
    final path = '${tempDir.path}/img_${width}x$height.png';
    await File(path).writeAsBytes(img.encodePng(image));
    return path;
  }

  group('isShrinkable', () {
    test('accepts common raster images, rejects the rest', () {
      expect(service.isShrinkable('image/jpeg'), isTrue);
      expect(service.isShrinkable('image/png; name=photo.png'), isTrue);
      expect(service.isShrinkable('image/webp'), isTrue);
      expect(service.isShrinkable('application/pdf'), isFalse);
      expect(service.isShrinkable('text/plain'), isFalse);
    });
  });

  test('probe reports pixel dimensions and byte size', () async {
    final path = await writePng(800, 600);
    final probe = await service.probe(path);
    expect(probe, isNotNull);
    expect(probe!.width, 800);
    expect(probe.height, 600);
    expect(probe.sizeBytes, greaterThan(0));
  });

  test('probe returns null for non-images', () async {
    final path = '${tempDir.path}/notimage.txt';
    await File(path).writeAsString('hello');
    expect(await service.probe(path), isNull);
  });

  test('probe returns null for a missing file', () async {
    expect(await service.probe('${tempDir.path}/does_not_exist.png'), isNull);
  });

  test('shrink clamps the longest edge, keeping aspect ratio', () async {
    final path = await writePng(2000, 1000);
    final bytes = await service.shrink(
      path,
      const ImageShrinkSettings(maxDimension: 800),
    );
    expect(bytes, isNotNull);
    final out = img.decodeJpg(bytes!)!;
    expect(out.width, 800);
    expect(out.height, 400);
  });

  test('shrink never upscales an already-small image', () async {
    final path = await writePng(300, 200);
    final bytes = await service.shrink(path, ImageShrinkSettings.defaults);
    final out = img.decodeJpg(bytes!)!;
    expect(out.width, 300);
    expect(out.height, 200);
  });

  test('lower JPEG quality produces fewer bytes', () async {
    final path = await writePng(1200, 900);
    final high = await service.shrink(
      path,
      const ImageShrinkSettings(maxDimension: 1200, jpegQuality: 95),
    );
    final low = await service.shrink(
      path,
      const ImageShrinkSettings(maxDimension: 1200, jpegQuality: 30),
    );
    expect(low!.length, lessThan(high!.length));
  });

  test('shrink returns null for a non-image file', () async {
    final path = '${tempDir.path}/notimage.txt';
    await File(path).writeAsString('hello');
    expect(
      await service.shrink(path, ImageShrinkSettings.defaults),
      isNull,
    );
  });
}
