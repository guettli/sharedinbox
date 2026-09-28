import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/services/update_service.dart';

void main() {
  group('isMiseInstall', () {
    test('detects the default mise data dir', () {
      expect(
        isMiseInstall(
          '/home/tg/.local/share/mise/installs/github-guettli-sharedinbox/'
          '0.1.2/sharedinbox',
        ),
        isTrue,
      );
    });

    test('detects a relocated MISE_DATA_DIR', () {
      expect(
        isMiseInstall('/opt/mise/installs/github-guettli-sharedinbox/0.1.2/'
            'sharedinbox'),
        isTrue,
      );
    });

    test('is false for a tarball unpacked by hand', () {
      expect(isMiseInstall('/home/tg/apps/sharedinbox/sharedinbox'), isFalse);
      expect(isMiseInstall('/usr/local/bin/sharedinbox'), isFalse);
    });
  });

  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
      expect(compareVersions('0.2.0', '0.10.0'), lessThan(0));
    });

    test('ignores a v prefix and pre-release/build suffixes', () {
      expect(compareVersions('v0.1.2', '0.1.2'), 0);
      expect(compareVersions('0.1.2+7', '0.1.2'), 0);
      expect(compareVersions('v0.1.3-beta', '0.1.2'), greaterThan(0));
    });

    test('pads missing components with zero', () {
      expect(compareVersions('0.1', '0.1.0'), 0);
      expect(compareVersions('0.1.1', '0.1'), greaterThan(0));
    });
  });

  group('updateFromLatestRelease', () {
    String release(String tag) => jsonEncode({
          'tag_name': tag,
          'html_url':
              'https://github.com/guettli/sharedinbox/releases/tag/$tag',
        });

    test('reports a newer release', () {
      final info = updateFromLatestRelease(
        body: release('v0.1.2'),
        runningVersion: '0.1.1',
        mise: false,
      );
      expect(info, isNotNull);
      expect(info!.latestVersion, '0.1.2');
      expect(
        info.downloadUrl,
        'https://github.com/guettli/sharedinbox/releases/tag/v0.1.2',
      );
      expect(info.upgradeCommand, isNull);
    });

    test('hands mise installs the upgrade command instead of a download', () {
      final info = updateFromLatestRelease(
        body: release('v0.1.2'),
        runningVersion: '0.1.1',
        mise: true,
      );
      expect(info!.upgradeCommand, kMiseUpgradeCommand);
    });

    test('stays quiet when the running build is current or ahead', () {
      expect(
        updateFromLatestRelease(
          body: release('v0.1.2'),
          runningVersion: '0.1.2',
          mise: true,
        ),
        isNull,
      );
      expect(
        updateFromLatestRelease(
          body: release('v0.1.2'),
          runningVersion: '0.1.3',
          mise: true,
        ),
        isNull,
      );
    });

    test('returns null on junk or an unknown running version', () {
      expect(
        updateFromLatestRelease(
          body: 'not json',
          runningVersion: '0.1.1',
          mise: false,
        ),
        isNull,
      );
      expect(
        updateFromLatestRelease(
          body: release('v0.1.2'),
          runningVersion: '',
          mise: false,
        ),
        isNull,
      );
    });
  });

  group('updateFromLatestJson', () {
    const body = '{"version":"abc1234",'
        '"linux":"https://sharedinbox.de/builds/2026/09/28/l.tar.gz",'
        '"windows":"https://sharedinbox.de/builds/2026/09/28/w.zip"}';

    test('reports any differing git hash for the platform', () {
      final info = updateFromLatestJson(
        body: body,
        platformKey: 'linux',
        runningVersion: 'def5678',
      );
      expect(info!.latestVersion, 'abc1234');
      expect(info.downloadUrl, endsWith('l.tar.gz'));
      expect(info.upgradeCommand, isNull);
    });

    test('is quiet when the hash matches', () {
      expect(
        updateFromLatestJson(
          body: body,
          platformKey: 'linux',
          runningVersion: 'abc1234',
        ),
        isNull,
      );
    });

    // The bug this guards: latest.json is versioned by git hash while releases
    // are SemVer. Feeding a release build's version in here would make every
    // check report an update forever, which is why the provider routes release
    // builds to the GitHub Releases channel instead.
    test('a SemVer running version would always look outdated', () {
      final info = updateFromLatestJson(
        body: body,
        platformKey: 'linux',
        runningVersion: '0.1.2',
      );
      expect(
        info,
        isNotNull,
        reason: 'documents why release builds must not use this channel',
      );
    });

    test('returns null for an unknown platform key or missing version', () {
      expect(
        updateFromLatestJson(
          body: body,
          platformKey: 'macos',
          runningVersion: 'def5678',
        ),
        isNull,
      );
      expect(
        updateFromLatestJson(
          body: '{}',
          platformKey: 'linux',
          runningVersion: 'def5678',
        ),
        isNull,
      );
      expect(
        updateFromLatestJson(
          body: body,
          platformKey: 'linux',
          runningVersion: '',
        ),
        isNull,
      );
    });
  });
}
