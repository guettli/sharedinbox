import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

const _kAppVersion = String.fromEnvironment('GIT_HASH');
const _kLatestJsonUrl = 'https://sharedinbox.de/latest.json';

class UpdateInfo {
  const UpdateInfo({required this.latestVersion, required this.downloadUrl});

  final String latestVersion;
  final String downloadUrl;
}

/// Returns an [UpdateInfo] when a newer Linux version is available, or null
/// if the app is up to date, the version is unknown, or the platform is not
/// Linux desktop.
final updateInfoProvider = FutureProvider<UpdateInfo?>((ref) async {
  if (!Platform.isLinux || _kAppVersion.isEmpty) return null;

  try {
    final resp = await http
        .get(Uri.parse(_kLatestJsonUrl))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final latest = json['version'] as String?;
    final url = json['linux'] as String?;
    if (latest == null || url == null) return null;
    if (latest == _kAppVersion) return null;
    return UpdateInfo(latestVersion: latest, downloadUrl: url);
  } catch (_) {
    return null;
  }
});
