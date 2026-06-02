import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sharedinbox/core/db_schema_version.dart';

const _gitHash = String.fromEnvironment('GIT_HASH');

/// Builds the About markdown table used in [AboutScreen] and sync log copies.
String buildAboutMarkdown({
  required BuildContext context,
  PackageInfo? pkg,
  required int imapCount,
  required int jmapCount,
  String? deviceModel,
}) {
  final size = MediaQuery.of(context).size;
  final pixelRatio = MediaQuery.of(context).devicePixelRatio;
  final physW = (size.width * pixelRatio).toInt();
  final physH = (size.height * pixelRatio).toInt();
  final version = pkg != null ? '${pkg.version}+${pkg.buildNumber}' : 'unknown';
  final versionDisplay = _gitHash.isNotEmpty
      ? '[$version](https://codeberg.org/guettli/sharedinbox/commit/$_gitHash)'
      : version;
  final osName = _capitalize(Platform.operatingSystem);
  final isDark = MediaQuery.of(context).platformBrightness == Brightness.dark;
  final locale = Localizations.localeOf(context).toString();
  final textScale = MediaQuery.of(
    context,
  ).textScaler.scale(1.0).toStringAsFixed(1);

  final gitCommitLine = _gitHash.isNotEmpty
      ? '| Git Commit | [$_gitHash](https://codeberg.org/guettli/sharedinbox/commit/$_gitHash) |\n'
      : '';
  final deviceModelLine =
      deviceModel != null ? '| Device Model | $deviceModel |\n' : '';

  return '## [sharedinbox.de](https://sharedinbox.de)\n\n'
      '| Property | Value |\n'
      '|----------|-------|\n'
      '| App Version | $versionDisplay |\n'
      '$gitCommitLine'
      '| Platform | ${Platform.operatingSystem} |\n'
      '| $osName Version | ${Platform.operatingSystemVersion} |\n'
      '$deviceModelLine'
      '| Resolution | ${physW}x$physH px'
      ' (logical: ${size.width.toInt()}x${size.height.toInt()} pt,'
      ' ratio: ${pixelRatio.toStringAsFixed(1)}x) |\n'
      '| Dart Version | ${Platform.version.split(' ').first} |\n'
      '| Processors | ${Platform.numberOfProcessors} |\n'
      '| Dark Mode | ${isDark ? 'yes' : 'no'} |\n'
      '| Locale | $locale |\n'
      '| Text Scale | $textScale× |\n'
      '| DB Schema Version | $dbSchemaVersion |\n'
      '| IMAP Accounts | $imapCount |\n'
      '| JMAP Accounts | $jmapCount |\n';
}

/// Fetches device model string, or null when unavailable.
Future<String?> getDeviceModel() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return '${android.manufacturer} / ${android.model}';
    } else if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return ios.utsname.machine;
    }
  } catch (_) {}
  return null;
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
