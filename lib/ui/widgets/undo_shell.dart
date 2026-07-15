import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

/// Wraps the router shell so every action pushed onto [undoServiceProvider]
/// produces two complementary pieces of feedback rendered as Stack children
/// of the shell (never as Scaffold SnackBars).
///
/// Scaffold-based SnackBars were unreliable on Android: when a destructive
/// action fires from the single-mail top bar the source Scaffold unmounts
/// during the immediately-following route transition, and the queued snack
/// gets silently dropped even with a top-level `scaffoldMessengerKey`
/// (regressed #255 after the #236 fix). Owning both surfaces in the shell
/// removes the whole class of scaffold-lifetime bugs.
///
/// 1. `_AppBarFlashOverlay` — covers the top button bar with a large,
///    icon-and-label filled banner tinted in the action's colour, overlaid
///    with a diagonal-stripe pattern so the action is still distinguishable
///    on a colour-blind or grayscale display. Sits exactly where the user's
///    eyes were when tapping.
/// 2. `_BottomActionOverlay` — SnackBar-shaped bar with the same label,
///    the action icon, and an inline **Undo** button. Persists for 5 s and
///    survives every route transition because it's not a SnackBar.
class UndoShell extends ConsumerStatefulWidget {
  const UndoShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UndoShell> createState() => _UndoShellState();
}

class _UndoShellState extends ConsumerState<UndoShell> {
  static const _flashHoldDuration = Duration(milliseconds: 1400);
  static const _snackDisplayDuration = Duration(seconds: 5);

  _FeedbackDisplay? _flash;
  _FeedbackDisplay? _snack;
  Timer? _flashTimer;
  Timer? _snackTimer;

  @override
  void dispose() {
    _flashTimer?.cancel();
    _snackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<UndoAction>>(undoServiceProvider, (previous, next) {
      // Detect a *new* action by identity, not list length: once the log hits
      // its 10-entry cap `pushAction` produces `newList.length == state.length`
      // after trim, so a length-based gate would silently swallow every
      // subsequent notification.
      final prevLastId = previous?.lastOrNull?.id;
      final nextLast = next.lastOrNull;
      if (nextLast == null || nextLast.id == prevLastId) return;
      // Don't fire feedback for actions loaded from persistence on app
      // startup — only for actions pushed in this session.
      if (DateTime.now().difference(nextLast.timestamp).inSeconds >= 30) {
        return;
      }
      _handleAction(nextLast);
    });

    return Stack(
      children: [
        widget.child,
        if (_flash != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _AppBarFlashOverlay(display: _flash!),
          ),
        if (_snack != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: _BottomActionOverlay(
              display: _snack!,
              onUndo: _handleUndo,
              onDismiss: _dismissSnack,
            ),
          ),
      ],
    );
  }

  void _handleAction(UndoAction action) {
    final feedback = _feedbackFor(action, Theme.of(context).colorScheme);
    _showFlash(feedback);
    _showSnack(feedback);
  }

  void _showFlash(_FeedbackDisplay display) {
    _flashTimer?.cancel();
    setState(() => _flash = display);
    _flashTimer = Timer(_flashHoldDuration, () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _showSnack(_FeedbackDisplay display) {
    _snackTimer?.cancel();
    setState(() => _snack = display);
    _snackTimer = Timer(_snackDisplayDuration, () {
      if (mounted) setState(() => _snack = null);
    });
  }

  void _dismissSnack() {
    _snackTimer?.cancel();
    if (mounted) setState(() => _snack = null);
  }

  void _handleUndo() {
    _dismissSnack();
    unawaited(ref.read(undoServiceProvider.notifier).undo());
  }
}

/// Full-width overlay that sits exactly on top of the AppBar area (status-bar
/// padding + [kToolbarHeight]) and paints the action's colour, a diagonal
/// stripe pattern, a large icon, and a bold label. The pattern encodes the
/// action independently of hue so a colour-blind or monochrome display can
/// still distinguish delete / archive / spam.
class _AppBarFlashOverlay extends StatelessWidget {
  const _AppBarFlashOverlay({required this.display});

  final _FeedbackDisplay display;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final height = kToolbarHeight + topPadding;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        tween: Tween<double>(begin: 0, end: 1),
        builder: (ctx, t, child) => Opacity(opacity: t, child: child),
        child: Semantics(
          container: true,
          liveRegion: true,
          label: display.label,
          child: Material(
            color: display.background,
            elevation: 8,
            child: SizedBox(
              height: height,
              child: CustomPaint(
                painter: _PatternPainter(
                  pattern: display.pattern,
                  color: display.foreground.withValues(alpha: 0.22),
                ),
                child: Padding(
                  padding: EdgeInsets.only(top: topPadding),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(display.icon, color: display.foreground, size: 32),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          display.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: display.foreground,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            shadows: const [
                              Shadow(
                                color: Color(0x66000000),
                                offset: Offset(0, 1),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// SnackBar-shaped bar rendered at the bottom of the shell as a `Stack`
/// child. Behaves like a SnackBar (label + Undo action, 5 s auto-dismiss,
/// tap to close) but is not attached to any Scaffold, so it survives every
/// route transition on Android.
class _BottomActionOverlay extends StatelessWidget {
  const _BottomActionOverlay({
    required this.display,
    required this.onUndo,
    required this.onDismiss,
  });

  final _FeedbackDisplay display;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (ctx, t, child) => Transform.translate(
        offset: Offset(0, 32 * (1 - t)),
        child: Opacity(opacity: t, child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: display.background,
          elevation: 6,
          borderRadius: BorderRadius.circular(6),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: display.label,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(display.icon, color: display.foreground, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        display.label,
                        style: TextStyle(
                          color: display.foreground,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onUndo,
                      style: TextButton.styleFrom(
                        foregroundColor: display.undoColor,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      child: const Text('UNDO'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual style for the undo feedback. Both overlays render from the same
/// display so the flash and the bottom bar always agree on colour, icon,
/// pattern, and label.
class _FeedbackDisplay {
  const _FeedbackDisplay({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.undoColor,
    required this.pattern,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color undoColor;
  final _Pattern pattern;
}

/// Encodes the action type in a paint pattern so the flash is distinguishable
/// even when hue information is unavailable.
enum _Pattern { solid, forwardSlash, crossHatch }

class _PatternPainter extends CustomPainter {
  _PatternPainter({required this.pattern, required this.color});

  final _Pattern pattern;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pattern == _Pattern.solid) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    const spacing = 14.0;
    final start = -size.height;
    final end = size.width + size.height;
    var x = start;
    while (x < end) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
      x += spacing;
    }
    if (pattern == _Pattern.crossHatch) {
      x = start;
      while (x < end) {
        canvas.drawLine(
          Offset(x, size.height),
          Offset(x + size.height, 0),
          paint,
        );
        x += spacing;
      }
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.pattern != pattern || old.color != color;
}

_FeedbackDisplay _feedbackFor(UndoAction action, ColorScheme scheme) {
  final count = action.emailIds.length;
  final plural = count == 1 ? '' : 's';

  switch (action.type) {
    case UndoType.delete:
      return _FeedbackDisplay(
        label: 'Deleted $count email$plural',
        icon: Icons.delete,
        background: const Color(0xFFC62828),
        foreground: Colors.white,
        undoColor: Colors.white,
        pattern: _Pattern.solid,
      );
    case UndoType.snooze:
      return _FeedbackDisplay(
        label: 'Snoozed $count email$plural',
        icon: Icons.bedtime,
        background: scheme.inverseSurface,
        foreground: scheme.onInverseSurface,
        undoColor: scheme.inversePrimary,
        pattern: _Pattern.solid,
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
            pattern: _Pattern.forwardSlash,
          );
        case 'junk':
          return _FeedbackDisplay(
            label: 'Marked $count email$plural as spam',
            icon: Icons.report,
            background: const Color(0xFFE65100),
            foreground: Colors.white,
            undoColor: Colors.white,
            pattern: _Pattern.crossHatch,
          );
        default:
          return _FeedbackDisplay(
            label: '$count email$plural moved',
            icon: Icons.drive_file_move,
            background: scheme.inverseSurface,
            foreground: scheme.onInverseSurface,
            undoColor: scheme.inversePrimary,
            pattern: _Pattern.solid,
          );
      }
  }
}
