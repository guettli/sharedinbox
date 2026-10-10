// Loads Material fonts (Roboto + MaterialIcons) before any test runs so that
// golden/screenshot tests render real text instead of placeholder boxes.
//
// Flutter widget tests don't load fonts by default. This file is discovered
// automatically by `flutter test` for every test under test/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _allowDevPlaintextHosts();
  setUpAll(_loadMaterialFonts);
  await testMain();
}

/// Backend/integration tests reach a dev Stalwart over plaintext — JMAP over
/// http and ManageSieve over a plain socket — addressed by its docker service
/// name rather than localhost. Register those hosts so the credential-bearing
/// clients allow plaintext to them across the whole suite, not just the tests
/// that call `StalwartEnv.fromPlatform` first. A no-op when the vars are unset
/// (unit-test isolates, so their remote-plaintext rejection tests are
/// unaffected), and the clients ignore the set in release builds.
void _allowDevPlaintextHosts() {
  for (final key in const ['STALWART_URL', 'STALWART_IMAP_HOST']) {
    final value = Platform.environment[key];
    if (value == null || value.isEmpty) continue;
    // STALWART_URL is a full URL; STALWART_IMAP_HOST is a bare host.
    final host = value.contains('://') ? Uri.tryParse(value)?.host : value;
    if (host != null && host.isNotEmpty) {
      debugAllowedPlaintextHosts.add(host);
    }
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
