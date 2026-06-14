import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/error_boundary.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Host screen')),
        body: child,
      ),
    );

/// A widget that throws on every build.
class _ThrowingWidget extends StatelessWidget {
  const _ThrowingWidget(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    throw FlutterError(message);
  }
}

/// A widget whose throwing behaviour can be toggled by the test.
class _ToggleController {
  bool shouldThrow = true;
}

class _ToggleThrow extends StatefulWidget {
  const _ToggleThrow({required this.controller});
  final _ToggleController controller;

  @override
  State<_ToggleThrow> createState() => _ToggleThrowState();
}

class _ToggleThrowState extends State<_ToggleThrow> {
  @override
  Widget build(BuildContext context) {
    if (widget.controller.shouldThrow) {
      throw FlutterError('toggled error');
    }
    return const Text('recovered');
  }
}

void main() {
  // ErrorBoundary depends on the boundary-aware ErrorWidget.builder installed
  // by main.dart. The test binding resets it to the default between tests,
  // so install the production builder for each test.
  setUp(() {
    ErrorWidget.builder = (details) => BoundaryAwareErrorWidget(
          details: details,
          fallback: (d) => Material(
            child: Text('global-fallback: ${d.exception}'),
          ),
        );
  });

  testWidgets(
    'build error inside ErrorBoundary is caught — surrounding chrome survives',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ErrorBoundary(
            label: 'Body',
            child: _ThrowingWidget('boom'),
          ),
        ),
      );
      // First pump runs the boundary's microtask listener; second pump renders
      // the fallback with the captured error.
      await tester.pump();

      // Acknowledge the build exception so the test framework does not fail
      // at teardown — this is exactly the kind of exception ErrorBoundary
      // exists to contain.
      expect(tester.takeException(), isA<FlutterError>());

      // The AppBar (outside the boundary) is still present.
      expect(find.text('Host screen'), findsOneWidget);

      // The default fallback shows the label.
      expect(find.text('Body could not be rendered'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // The global fallback (CrashScreen substitute) must NOT have been used.
      expect(find.textContaining('global-fallback'), findsNothing);
    },
  );

  testWidgets('sibling widgets continue to render normally', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const Column(
          children: [
            Text('alive sibling'),
            ErrorBoundary(child: _ThrowingWidget('boom')),
            Text('still alive sibling'),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isA<FlutterError>());

    expect(find.text('alive sibling'), findsOneWidget);
    expect(find.text('still alive sibling'), findsOneWidget);
    expect(
      find.text('This part of the screen could not be rendered'),
      findsOneWidget,
    );
  });

  testWidgets('Retry resets the boundary and re-renders the child', (
    tester,
  ) async {
    final controller = _ToggleController();
    await tester.pumpWidget(
      _wrap(
        ErrorBoundary(child: _ToggleThrow(controller: controller)),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isA<FlutterError>());
    expect(find.text('Retry'), findsOneWidget);

    controller.shouldThrow = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(find.text('recovered'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('custom fallbackBuilder overrides default UI', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ErrorBoundary(
          fallbackBuilder: (ctx, err, stack, reset) => Text('custom: $err'),
          child: const _ThrowingWidget('boom'),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isA<FlutterError>());

    expect(find.textContaining('custom: '), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'build error outside any boundary falls through to the global fallback',
    (tester) async {
      await tester.pumpWidget(
        _wrap(const _ThrowingWidget('uncaught')),
      );
      await tester.pump();
      expect(tester.takeException(), isA<FlutterError>());

      expect(find.textContaining('global-fallback'), findsOneWidget);
    },
  );

  testWidgets(
    'ErrorBoundaryScope.reportError routes async errors to the boundary',
    (tester) async {
      late BuildContext innerContext;
      await tester.pumpWidget(
        _wrap(
          ErrorBoundary(
            label: 'Async area',
            child: Builder(
              builder: (ctx) {
                innerContext = ctx;
                return const Text('healthy');
              },
            ),
          ),
        ),
      );

      expect(find.text('healthy'), findsOneWidget);

      final captured = ErrorBoundaryScope.reportError(
        innerContext,
        StateError('async failure'),
      );
      expect(captured, isTrue);
      await tester.pump();
      await tester.pump();

      expect(find.text('Async area could not be rendered'), findsOneWidget);
      expect(find.text('healthy'), findsNothing);
    },
  );

  testWidgets(
    'ErrorBoundaryScope.reportError returns false without an ancestor boundary',
    (tester) async {
      late BuildContext innerContext;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (ctx) {
              innerContext = ctx;
              return const Text('healthy');
            },
          ),
        ),
      );

      final flutterErrors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = flutterErrors.add;
      addTearDown(() => FlutterError.onError = previous);

      final captured = ErrorBoundaryScope.reportError(
        innerContext,
        StateError('orphan'),
      );
      expect(captured, isFalse);
      expect(flutterErrors, hasLength(1));
      expect(flutterErrors.first.exception, isA<StateError>());
    },
  );
}
