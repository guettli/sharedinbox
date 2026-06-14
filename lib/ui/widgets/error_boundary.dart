import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Wraps [child] so that a build- or paint-time exception in the subtree shows
/// a compact inline fallback instead of escalating to the global crash screen.
///
/// Works in two pieces:
///
///  * The global `ErrorWidget.builder` (installed in `main.dart`) returns a
///    [BoundaryAwareErrorWidget]. When Flutter replaces the failing widget,
///    that replacement looks up the nearest enclosing [ErrorBoundary] via an
///    `InheritedWidget` and writes the error to its [_BoundaryController]. If
///    no boundary is found, the substitute renders the global fallback
///    (typically `CrashScreen`).
///
///  * For asynchronous failures originating inside the subtree, call
///    [ErrorBoundaryScope.reportError] from a [BuildContext] inside the
///    boundary. The error propagates to the nearest boundary the same way.
///
/// Use it around components that can fail on input data outside our control
/// (e.g. the HTML email renderer), so a malformed email does not take down the
/// surrounding screen.
class ErrorBoundary extends StatefulWidget {
  const ErrorBoundary({
    super.key,
    required this.child,
    this.label,
    this.fallbackBuilder,
  });

  final Widget child;

  /// Short label shown in the default fallback (e.g. "Email body").
  final String? label;

  /// Optional override for the fallback UI. Receives the captured error, the
  /// stack trace (may be null), and a `reset` callback that clears the error
  /// and re-renders [child].
  final Widget Function(
    BuildContext context,
    Object error,
    StackTrace? stack,
    VoidCallback reset,
  )? fallbackBuilder;

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  late final _BoundaryController _controller = _BoundaryController()
    ..addListener(_onErrorChanged);

  void _onErrorChanged() {
    if (!mounted) return;
    // The substitute calls capture() from inside its build, so we cannot
    // setState synchronously. Defer to a microtask so the rebuild happens
    // after the current build pass.
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _reset() {
    if (!mounted) return;
    _controller.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onErrorChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _controller.error;
    if (error != null) {
      final builder = widget.fallbackBuilder;
      if (builder != null) {
        return builder(context, error, _controller.stack, _reset);
      }
      return _DefaultErrorFallback(
        label: widget.label,
        error: error,
        stack: _controller.stack,
        onRetry: _reset,
      );
    }
    return _ErrorBoundaryScope(
      controller: _controller,
      child: widget.child,
    );
  }
}

/// Mutable error slot shared between the [ErrorBoundary] and any
/// [BoundaryAwareErrorWidget] substituted into its subtree. Implemented as a
/// [ChangeNotifier] so a single listener (the boundary) rebuilds on capture.
class _BoundaryController extends ChangeNotifier {
  Object? error;
  StackTrace? stack;

  void capture(Object newError, StackTrace? newStack) {
    if (error != null) return; // first error wins until reset
    error = newError;
    stack = newStack;
    notifyListeners();
  }

  void clear() {
    error = null;
    stack = null;
  }
}

class _ErrorBoundaryScope extends InheritedWidget {
  const _ErrorBoundaryScope({
    required this.controller,
    required super.child,
  });

  final _BoundaryController controller;

  @override
  bool updateShouldNotify(_ErrorBoundaryScope oldWidget) =>
      controller != oldWidget.controller;

  static _BoundaryController? of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ErrorBoundaryScope>();
    return scope?.controller;
  }
}

/// Helpers callable from inside an [ErrorBoundary]'s subtree.
abstract final class ErrorBoundaryScope {
  /// Forwards [error] to the nearest enclosing [ErrorBoundary] above [context].
  /// Returns true if a boundary captured it; false if none was found (in which
  /// case the error is reported to [FlutterError] as a normal uncaught error).
  static bool reportError(
    BuildContext context,
    Object error, [
    StackTrace? stack,
  ]) {
    final controller = _ErrorBoundaryScope.of(context);
    if (controller == null) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      return false;
    }
    controller.capture(error, stack);
    return true;
  }
}

/// Internal hook for `main.dart`: the boundary-aware `ErrorWidget.builder`
/// returns this widget. It looks for an enclosing [ErrorBoundary] and writes
/// the error into the boundary's controller; if none exists, it renders
/// [fallback] (typically the full-screen `CrashScreen`).
class BoundaryAwareErrorWidget extends StatelessWidget {
  const BoundaryAwareErrorWidget({
    super.key,
    required this.details,
    required this.fallback,
  });

  final FlutterErrorDetails details;
  final Widget Function(FlutterErrorDetails details) fallback;

  @override
  Widget build(BuildContext context) {
    final controller = _ErrorBoundaryScope.of(context);
    if (controller != null) {
      controller.capture(details.exception, details.stack);
      // Render an invisible placeholder for this single frame. The boundary's
      // listener fires on the next microtask, marks it dirty, and the next
      // pump rebuilds with the fallback in this slot's place.
      return const SizedBox.shrink();
    }
    return fallback(details);
  }
}

class _DefaultErrorFallback extends StatelessWidget {
  const _DefaultErrorFallback({
    required this.label,
    required this.error,
    required this.stack,
    required this.onRetry,
  });

  final String? label;
  final Object error;
  final StackTrace? stack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = label != null
        ? '$label could not be rendered'
        : 'This part of the screen could not be rendered';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(
                'Show details',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
              ),
              iconColor: scheme.onErrorContainer,
              collapsedIconColor: scheme.onErrorContainer,
              children: [
                SelectableText(
                  error.toString(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: scheme.onErrorContainer,
                  ),
                ),
                if (stack != null && kDebugMode) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    stack.toString(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
