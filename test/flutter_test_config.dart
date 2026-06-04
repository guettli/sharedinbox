// Loads Material fonts (Roboto + MaterialIcons) before any test runs so that
// golden/screenshot tests render real text instead of placeholder boxes.
//
// Flutter widget tests don't load fonts by default. This file is discovered
// automatically by `flutter test` for every test under test/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUpAll(_loadMaterialFonts);
  await testMain();
}

Future<void> _loadMaterialFonts() async {
  // Locate Flutter's cached material fonts relative to the flutter_tester executable.
  // Layout: <flutter-root>/bin/cache/artifacts/engine/linux-x64/flutter_tester
  //          <flutter-root>/bin/cache/artifacts/material_fonts/
  final cacheDir =
      File(Platform.resolvedExecutable).parent.parent.parent.parent;
  final fontsDir = '${cacheDir.path}/artifacts/material_fonts';

  Future<ByteData> load(String name) async {
    final bytes = await File('$fontsDir/$name').readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  await (FontLoader('Roboto')
        ..addFont(load('Roboto-Regular.ttf'))
        ..addFont(load('Roboto-Medium.ttf'))
        ..addFont(load('Roboto-Bold.ttf'))
        ..addFont(load('Roboto-Italic.ttf'))
        ..addFont(load('Roboto-MediumItalic.ttf'))
        ..addFont(load('Roboto-BoldItalic.ttf')))
      .load();

  await (FontLoader('MaterialIcons')
        ..addFont(load('MaterialIcons-Regular.otf')))
      .load();
}
