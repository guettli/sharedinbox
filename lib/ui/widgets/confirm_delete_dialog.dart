import 'package:flutter/material.dart';

/// Asks before something is deleted: a dialog with Cancel and a red Delete
/// button. Returns true only when Delete was tapped.
Future<bool> showConfirmDelete(
  BuildContext context, {
  required String title,
  required String content,
  Key? confirmKey,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: confirmKey,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
