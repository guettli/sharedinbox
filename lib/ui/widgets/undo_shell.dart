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
        final action = next.last;
        // Don't show a snackbar for actions loaded from persistence on app
        // startup — only for actions pushed in this session.
        if (DateTime.now().difference(action.timestamp).inSeconds < 30) {
          _showUndoSnackbar(context, ref, action);
        }
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
    final feedback = _feedbackFor(action, Theme.of(context).colorScheme);
    scaffoldMessenger.clearSnackBars();
    scaffoldMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        backgroundColor: feedback.background,
        content: Row(
          children: [
            Icon(feedback.icon, color: feedback.foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                feedback.label,
                style: TextStyle(
                  color: feedback.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Undo',
          textColor: feedback.undoColor,
          onPressed: () => ref.read(undoServiceProvider.notifier).undo(),
        ),
      ),
    );
  }
}

/// Visual style for the undo snackbar. `null` colours fall back to the
/// scaffold's default theming so we only override for the actions that
/// benefit from a distinctive tint.
class _FeedbackDisplay {
  const _FeedbackDisplay({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.undoColor,
  });

  final String label;
  final IconData icon;
  final Color? background;
  final Color? foreground;
  final Color? undoColor;
}

_FeedbackDisplay _feedbackFor(UndoAction action, ColorScheme scheme) {
  final count = action.emailIds.length;
  final plural = count == 1 ? '' : 's';

  switch (action.type) {
    case UndoType.delete:
      return _FeedbackDisplay(
        label: 'Deleted $count email$plural',
        icon: Icons.delete,
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
        undoColor: scheme.error,
      );
    case UndoType.snooze:
      return _FeedbackDisplay(
        label: 'Snoozed $count email$plural',
        icon: Icons.bedtime,
        background: null,
        foreground: null,
        undoColor: Colors.redAccent,
      );
    case UndoType.move:
      switch (action.destinationMailboxRole) {
        case 'archive':
          return _FeedbackDisplay(
            label: 'Archived $count email$plural',
            icon: Icons.archive,
            background: const Color(0xFF2E7D32),
            foreground: Colors.white,
            undoColor: Colors.white,
          );
        case 'junk':
          return _FeedbackDisplay(
            label: 'Marked $count email$plural as spam',
            icon: Icons.report,
            background: const Color(0xFFE65100),
            foreground: Colors.white,
            undoColor: Colors.white,
          );
        default:
          return _FeedbackDisplay(
            label: '$count email$plural moved',
            icon: Icons.drive_file_move,
            background: null,
            foreground: null,
            undoColor: Colors.redAccent,
          );
      }
  }
}
