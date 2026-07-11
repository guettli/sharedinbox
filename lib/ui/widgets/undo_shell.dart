import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/root_messenger.dart';

/// Wraps the router shell so every action pushed onto [undoServiceProvider]
/// produces two, complementary pieces of feedback:
///
/// 1. A tinted SnackBar with an Undo action, dispatched through the top-level
///    [rootScaffoldMessengerKey] so it survives concurrent route transitions
///    (see #233 — on Android the snack was being dropped when the detail route
///    popped in the same frame the messenger was resolved).
/// 2. A short in-tree banner overlay that slides in at the top of the shell
///    before fading out ~1.4 s later. This is the belt-and-braces confirmation
///    the user sees even if a subsequent navigation would have hidden the
///    SnackBar underneath the destination screen's chrome.
class UndoShell extends ConsumerStatefulWidget {
  const UndoShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UndoShell> createState() => _UndoShellState();
}

class _UndoShellState extends ConsumerState<UndoShell> {
  static const _bannerDisplayDuration = Duration(milliseconds: 1400);

  _FeedbackDisplay? _banner;
  Timer? _bannerTimer;

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<UndoAction>>(undoServiceProvider, (previous, next) {
      if (next.isNotEmpty &&
          (previous == null || previous.length < next.length)) {
        final action = next.last;
        // Don't fire feedback for actions loaded from persistence on app
        // startup — only for actions pushed in this session.
        if (DateTime.now().difference(action.timestamp).inSeconds < 30) {
          _handleAction(action);
        }
      }
    });

    return Stack(
      children: [
        widget.child,
        if (_banner != null)
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0,
            right: 0,
            child: _ActionBanner(display: _banner!),
          ),
      ],
    );
  }

  void _handleAction(UndoAction action) {
    final feedback = _feedbackFor(action, Theme.of(context).colorScheme);
    _showBanner(feedback);
    // Defer to the next frame so any in-flight `context.pop()` from the
    // action handler has time to settle first. On Android that ordering
    // was the difference between "snack shown" and "snack silently dropped".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = rootScaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(
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
    });
  }

  void _showBanner(_FeedbackDisplay display) {
    _bannerTimer?.cancel();
    setState(() => _banner = display);
    _bannerTimer = Timer(_bannerDisplayDuration, () {
      if (mounted) setState(() => _banner = null);
    });
  }
}

/// Animated bar rendered at the top of the shell as a persistent, in-tree
/// confirmation of the last action. Complements the SnackBar; guaranteed
/// visible even if the destination route hides bottom chrome.
class _ActionBanner extends StatelessWidget {
  const _ActionBanner({required this.display});

  final _FeedbackDisplay display;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        tween: Tween<double>(begin: 0, end: 1),
        builder: (ctx, t, child) => Transform.translate(
          offset: Offset(0, -32 * (1 - t)),
          child: Opacity(opacity: t, child: child),
        ),
        child: Material(
          color: display.background ??
              Theme.of(context).colorScheme.inverseSurface,
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 14,
            ),
            child: Row(
              children: [
                Icon(
                  display.icon,
                  color: display.foreground ?? Colors.white,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    display.label,
                    style: TextStyle(
                      color: display.foreground ?? Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual style for the undo feedback. `null` colours fall back to theme
/// defaults so we only override for actions that benefit from a distinctive
/// tint.
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
