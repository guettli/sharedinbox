import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Result of saving a raw .eml file.
@immutable
class RawEmailSaveResult {
  const RawEmailSaveResult({
    required this.path,
    required this.displayLocation,
    required this.isPublic,
  });

  /// Filesystem path (or content:// URI on Android API 29+).
  final String path;

  /// Human-readable location shown to the user (e.g. "Download/foo.eml").
  final String displayLocation;

  /// Whether the file was written to a public, system-indexed location
  /// (i.e. surfaces in the system file picker's "Recent" list). False
  /// for desktop/fallback writes into a temp directory.
  final bool isPublic;
}

/// Saves a raw .eml file to the platform's user-visible Downloads location
/// when possible, so it shows up in the system file picker's "Recently used"
/// list. Falls back to the app's temporary directory on platforms without a
/// dedicated downloads location.
///
/// Returns the saved file's path and a display string for SnackBars.
Future<RawEmailSaveResult> saveRawEmail({
  required String filename,
  required String content,
}) async {
  if (rawEmailIsAndroid()) {
    final path = await androidRawEmailChannel.invokeMethod<String>(
      'saveToDownloads',
      <String, Object?>{'filename': filename, 'content': content},
    );
    if (path == null) {
      throw const _RawEmailSaveException('Android save returned no path');
    }
    return RawEmailSaveResult(
      path: path,
      displayLocation: 'Download/$filename',
      isPublic: true,
    );
  }

  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsString(content);
  return RawEmailSaveResult(
    path: file.path,
    displayLocation: filename,
    isPublic: false,
  );
}

/// Whether the Android MediaStore method channel should be used. Tests can
/// override this to exercise the Android branch on non-Android hosts.
@visibleForTesting
bool Function() rawEmailIsAndroid = () => !kIsWeb && Platform.isAndroid;

/// The MethodChannel handled by `RawEmailDownloader.kt`. Exposed so tests can
/// install a mock handler via `tester.binding.defaultBinaryMessenger`.
@visibleForTesting
const MethodChannel androidRawEmailChannel = MethodChannel(
  'sharedinbox/raw_email_downloader',
);

class _RawEmailSaveException implements Exception {
  const _RawEmailSaveException(this.message);
  final String message;
  @override
  String toString() => message;
}
