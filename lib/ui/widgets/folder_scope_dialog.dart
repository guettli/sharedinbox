import 'package:flutter/material.dart';

/// What the user chose for a folder in the folder-scope dialog (#844).
enum FolderScopeChoice {
  /// Show only mail from that folder.
  focus,

  /// Hide mail from that folder.
  exclude,
}

/// Asks whether the user wants to focus the search on [folderDisplayName] or
/// exclude it. Returns the chosen action, or null when the dialog is dismissed.
///
/// Opened by tapping a folder name on a search result row; the caller applies
/// the choice as a client-side view filter over the current results (#844).
Future<FolderScopeChoice?> showFolderScopeDialog(
  BuildContext context, {
  required String folderDisplayName,
}) {
  return showDialog<FolderScopeChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(folderDisplayName),
      content: const Text('Filter the search results by this folder?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(FolderScopeChoice.exclude),
          child: const Text('Exclude folder'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(FolderScopeChoice.focus),
          child: const Text('Only this folder'),
        ),
      ],
    ),
  );
}
