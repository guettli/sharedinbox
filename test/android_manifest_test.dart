import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the native Android config that keeps `mailto:` links working (#463).
///
/// These assertions live against the manifest file itself because the failing
/// behaviour — Flutter's automatic deep-linking hijacking a `mailto:` intent
/// and routing it into GoRouter ("Page Not Found") — is native config that no
/// widget test exercises.
void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  test('Flutter deep-linking is disabled so MailIntentBridge owns intents', () {
    final match = RegExp(
      r'flutter_deeplinking_enabled"\s+android:value="(\w+)"',
    ).firstMatch(manifest);
    expect(
      match,
      isNotNull,
      reason: 'flutter_deeplinking_enabled meta-data must be present',
    );
    expect(
      match!.group(1),
      'false',
      reason: 'deep-linking must stay off or mailto: links break (#463)',
    );
  });

  test('mailto: intent-filter is still registered', () {
    expect(
      manifest.contains('<data android:scheme="mailto"/>'),
      isTrue,
      reason: 'the app must still advertise itself as a mailto: handler',
    );
  });

  test('cloud backup excludes the database and app files (crypto review F3)',
      () {
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    final modern = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    final cloud = RegExp(r'<cloud-backup>(.*?)</cloud-backup>', dotAll: true)
        .firstMatch(modern)!
        .group(1)!;
    final legacy = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    for (final rules in [cloud, legacy]) {
      expect(rules, contains('<exclude domain="database" path="." />'));
      expect(rules, contains('<exclude domain="file" path="." />'));
    }
  });
}
