import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/mime_filename.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// Asks the user where to save a file named [suggestedName]. Returns the
/// chosen path, or null when the dialog was cancelled.
typedef SaveLocationPicker = Future<String?> Function(String suggestedName);

// file_picker writes `bytes` to the chosen path itself but skips empty ones,
// so empty bytes make it a pure location picker; [saveFileAs] then copies the
// cached file there without loading it into memory.
Future<String?> _nativeSaveDialog(String suggestedName) => FilePicker.saveFile(
      dialogTitle: 'Save attachment',
      fileName: suggestedName,
      bytes: Uint8List(0),
    );

/// The native "Save as…" dialog. Overridden in tests so no dialog opens.
final saveLocationPickerProvider =
    Provider<SaveLocationPicker>((ref) => _nativeSaveDialog);

/// Whether "Save as…" is offered: desktop only. Android and iOS hand files
/// to other apps (open/share) instead of saving them to a chosen path.
bool get supportsSaveAs => switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      _ => false,
    };

/// Shows the save dialog for [filename] (sanitised), then copies the file
/// returned by [source] there and reports the saved path in a snackbar.
///
/// [source] runs after the dialog, so a cancelled dialog costs no download.
/// Returns the saved path, or null when cancelled or failed.
Future<String?> saveFileAs(
  BuildContext context, {
  required SaveLocationPicker picker,
  required String filename,
  required Future<String> Function() source,
  String? emailId,
}) async {
  try {
    final target = await picker(safeFileName(filename));
    if (target == null) return null;
    final from = await source();
    await File(from).copy(target);
    if (context.mounted) {
      context.showAppSnackBar(
        'Saved to $target',
        event: 'attachment.saved',
        emailId: emailId,
        data: {'filename': filename},
      );
    }
    return target;
  } catch (e, stack) {
    if (context.mounted) {
      context.showAppSnackBar(
        'Saving file failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'attachment.save_failed',
        emailId: emailId,
        data: {'filename': filename},
        error: e,
        stack: stack,
      );
    }
    return null;
  }
}
