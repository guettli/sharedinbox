import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoShell extends ConsumerWidget {
  const UndoShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<UndoAction?>(undoServiceProvider, (previous, next) {
      if (next != null && previous?.id != next.id) {
        _showUndoSnackbar(context, ref, next);
      }
    });

    return child;
  }

  void _showUndoSnackbar(
    BuildContext context,
    WidgetRef ref,
    UndoAction action,
  ) {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.clearSnackBars();
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(
          action.type == UndoType.delete
              ? '${action.emailIds.length} email(s) moved to Trash'
              : '${action.emailIds.length} email(s) moved',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => ref.read(undoServiceProvider.notifier).undo(),
        ),
      ),
    );
  }
}
