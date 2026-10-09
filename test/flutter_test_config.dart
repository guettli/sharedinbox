// Loads Material fonts (Roboto + MaterialIcons) before any test runs so that
// golden/screenshot tests render real text instead of placeholder boxes.
//
// Flutter widget tests don't load fonts by default. This file is discovered
// automatically by `flutter test` for every test under test/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _allowDevJmapHostOverHttp();
  setUpAll(_loadMaterialFonts);
  await testMain();
}

/// Backend/integration tests reach a dev Stalwart over plaintext http,
/// addressed by its docker service name via `STALWART_URL`. Register that host
/// so `JmapClient.connect` allows http to it across the whole suite — not just
/// the tests that happen to call `StalwartEnv.fromPlatform` first. A no-op when
/// the var is unset (unit-test isolates, so their remote-http rejection tests
/// are unaffected), and `JmapClient` ignores the set in release builds.
void _allowDevJmapHostOverHttp() {
  final url = Platform.environment['STALWART_URL'];
  if (url == null || url.isEmpty) return;
  final host = Uri.tryParse(url)?.host;
  if (host != null && host.isNotEmpty) {
    JmapClient.debugAllowedHttpHosts.add(host);
  }
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
