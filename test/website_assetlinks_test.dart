import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';

/// Guards the Digital Asset Links file that lets the Android app use
/// passkeys of the rpId [passkeyRpId] (#1412). Static web serves it on
/// keys.sharedinbox.de (guettli/gitops#1219), which serves nothing else.
void main() {
  final links = jsonDecode(
    File('website/static/.well-known/assetlinks.json').readAsStringSync(),
  ) as List<dynamic>;

  test('grants get_login_creds to de.sharedinbox.mua by SHA-256 only', () {
    final statement = links.single as Map<String, dynamic>;
    expect(
      statement['relation'],
      ['delegate_permission/common.get_login_creds'],
    );
    final target = statement['target'] as Map<String, dynamic>;
    expect(target['namespace'], 'android_app');
    expect(target['package_name'], 'de.sharedinbox.mua');
    final prints = (target['sha256_cert_fingerprints'] as List).cast<String>();
    expect(prints, isNotEmpty);
    for (final p in prints) {
      expect(
        p,
        matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')),
        reason: 'SHA-256, upper-case hex pairs separated by colons',
      );
    }
  });

  test('the rpId is the dedicated keys host', () {
    expect(passkeyRpId, 'keys.sharedinbox.de');
  });
}
