import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Git hash of the running build, injected by every packaging path.
const _kAppVersion = String.fromEnvironment('GIT_HASH');

/// SemVer of the running build. Injected **only** by `task release-linux`
/// (see `ci/main.go` → `PackageLinuxRelease`), i.e. only for binaries that came
/// from a GitHub Release — which is what mise installs.
///
/// Its presence switches the update check from the hourly `latest.json`
/// snapshot channel to the GitHub Releases channel. Both channels are live at
/// the same time and their version strings are not comparable: `latest.json`
/// carries a git hash, a release carries `0.1.2`. Comparing across them would
/// report "update available" on every single check.
const _kReleaseVersion = String.fromEnvironment('RELEASE_VERSION');

const _kLatestJsonUrl = 'https://sharedinbox.de/latest.json';
const _kLatestReleaseUrl =
    'https://api.github.com/repos/guettli/sharedinbox/releases/latest';

/// Upgrade command for a mise-managed install. A mise install dir is versioned
/// and owned by mise, so downloading a tarball over it is wrong.
///
/// The argument must be the TOOL name (`github:<owner>/<repo>`), not the `bin`
/// name: `mise up sharedinbox` matches no installed tool and exits 0 with
/// "All tools are up to date", leaving the user stranded on the old version
/// with a banner that never clears. `CheckMiseInstall` asserts this command
/// actually resolves the tool.
const kMiseUpgradeCommand = 'mise up github:guettli/sharedinbox';

class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    this.upgradeCommand,
  });

  final String latestVersion;
  final String downloadUrl;

  /// Shell command that upgrades this install in place, or null when the user
  /// should download [downloadUrl] instead. Set for mise-managed installs.
  final String? upgradeCommand;
}

/// Whether the running executable was installed by mise.
///
/// mise installs tools under `<data dir>/installs/<backend>/<tool>/<version>/`.
/// This matches the `mise/installs/` tail of the default data dir
/// (`~/.local/share/mise`, or any `MISE_DATA_DIR` ending in `mise`), which is
/// specific enough not to fire on an unrelated path containing `installs`.
///
/// A `MISE_DATA_DIR` whose last segment is not `mise` is not detected; that
/// user sees the download link instead of the upgrade command, which is a
/// wrong hint rather than a broken app.
@visibleForTesting
bool isMiseInstall(String resolvedExecutable) =>
    resolvedExecutable.contains('/mise/installs/');

/// Compares two dotted version strings numerically. Pre-release and build
/// suffixes (`-beta`, `+3`) are ignored. Returns <0, 0 or >0 like [Comparable].
@visibleForTesting
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.replaceFirst(RegExp(r'^v'), '').split(RegExp('[-+]')).first;
    return core.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  }

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Parses `latest.json` (the hourly snapshot channel, versioned by git hash).
///
/// Any difference from [runningVersion] counts as an update: consecutive git
/// hashes are not ordered, so "different" is the only signal available.
@visibleForTesting
UpdateInfo? updateFromLatestJson({
  required String body,
  required String platformKey,
  required String runningVersion,
}) {
  if (runningVersion.isEmpty) return null;
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  // Tolerate a malformed payload: these are exported for testing and must
  // honour "returns null on junk" rather than throw a cast error.
  final latest = json['version'];
  final url = json[platformKey];
  if (latest is! String || url is! String) return null;
  if (latest == runningVersion) return null;
  return UpdateInfo(latestVersion: latest, downloadUrl: url);
}

/// Parses the GitHub "latest release" payload (the channel mise installs from).
///
/// Unlike [updateFromLatestJson] both versions are SemVer here, so this reports
/// an update only when the release is actually *newer* — a release build that
/// is ahead of the latest published release (a local build of an unreleased
/// tag) stays quiet.
@visibleForTesting
UpdateInfo? updateFromLatestRelease({
  required String body,
  required String runningVersion,
  required bool mise,
}) {
  if (runningVersion.isEmpty) return null;
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final tag = json['tag_name'];
  if (tag is! String || tag.isEmpty) return null;
  if (compareVersions(tag, runningVersion) <= 0) return null;
  final htmlUrl = json['html_url'];
  final url = htmlUrl is String && htmlUrl.isNotEmpty
      ? htmlUrl
      : 'https://github.com/guettli/sharedinbox/releases/tag/$tag';
  return UpdateInfo(
    latestVersion: tag.replaceFirst(RegExp(r'^v'), ''),
    downloadUrl: url,
    upgradeCommand: mise ? kMiseUpgradeCommand : null,
  );
}

/// Returns an [UpdateInfo] when a newer Linux or Windows version is available,
/// or null if the app is up to date, the version is unknown, or the platform
/// is not a supported desktop.
final updateInfoProvider = FutureProvider<UpdateInfo?>((ref) async {
  final platformKey = Platform.isLinux
      ? 'linux'
      : Platform.isWindows
          ? 'windows'
          : null;
  if (platformKey == null) return null;
  // A local `flutter run` has neither define set; there is nothing to compare,
  // so return before spending a network round-trip on it.
  if (_kAppVersion.isEmpty && _kReleaseVersion.isEmpty) return null;

  final mise = isMiseInstall(Platform.resolvedExecutable);

  // Release builds (mise installs and GitHub Release downloads alike) must be
  // compared against GitHub Releases, never against latest.json's git hash.
  if (_kReleaseVersion.isNotEmpty) {
    try {
      final resp = await http
          .get(Uri.parse(_kLatestReleaseUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      return updateFromLatestRelease(
        body: resp.body,
        runningVersion: _kReleaseVersion,
        mise: mise,
      );
    } catch (_) {
      return null;
    }
  }

  // A binary inside a mise install dir that carries no RELEASE_VERSION did not
  // come from a release, so there is nothing its version can be compared with.
  if (mise) return null;

  try {
    final resp = await http
        .get(Uri.parse(_kLatestJsonUrl))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return updateFromLatestJson(
      body: resp.body,
      platformKey: platformKey,
      runningVersion: _kAppVersion,
    );
  } catch (_) {
    return null;
  }
});
