import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoShell extends ConsumerWidget {
  const UndoShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<List<UndoAction>>(undoServiceProvider, (previous, next) {
      if (next.isNotEmpty &&
          (previous == null || previous.length < next.length)) {
        _showUndoSnackbar(context, ref, next.last);
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
          textColor: Colors.redAccent,
          onPressed: () => ref.read(undoServiceProvider.notifier).undo(),
        ),
      ),
    );
  }
}
