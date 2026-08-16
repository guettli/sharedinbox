import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the native Android night theme that keeps light emails readable (#548).
///
/// On API 29-32 the WebView heuristically force-darkens light email bodies,
/// turning dark text on white into black-on-black. Disabling force-dark on the
/// activity themes is native config that no widget test exercises, so the guard
/// lives against the styles file itself.
void main() {
  final styles = File(
    'android/app/src/main/res/values-night/styles.xml',
  ).readAsStringSync();

  for (final theme in ['LaunchTheme', 'NormalTheme']) {
    test('$theme disables WebView force-dark so light emails stay readable', () {
      final match = RegExp(
        'name="$theme".*?</style>',
        dotAll: true,
      ).firstMatch(styles);
      expect(match, isNotNull, reason: '$theme must be defined');
      expect(
        match!.group(0),
        contains(
          '<item name="android:forceDarkAllowed">false</item>',
        ),
        reason: 'force-dark must stay off or light emails render '
            'black-on-black in dark mode (#548)',
      );
    });
  }
}
