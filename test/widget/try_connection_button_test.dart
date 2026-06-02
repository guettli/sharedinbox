import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/try_connection_button.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    useMaterial3: true,
  ),
  home: Scaffold(body: child),
);

void main() {
  group('TryConnectionButton', () {
    testWidgets('shows "Try connection" button when idle', (tester) async {
      await tester.pumpWidget(
        _wrap(const TryConnectionButton(testing: false, onPressed: null)),
      );
      expect(find.text('Try connection'), findsOneWidget);
    });

    testWidgets('shows spinner when testing', (tester) async {
      await tester.pumpWidget(
        _wrap(const TryConnectionButton(testing: true, onPressed: null)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Try connection'), findsNothing);
    });

    testWidgets('shows okMessage when provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TryConnectionButton(
            testing: false,
            onPressed: null,
            okMessage: 'Connected!',
          ),
        ),
      );
      expect(find.text('Connected!'), findsOneWidget);
    });

    testWidgets('shows errorMessage when provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TryConnectionButton(
            testing: false,
            onPressed: null,
            errorMessage: 'Connection failed',
          ),
        ),
      );
      expect(find.text('Connection failed'), findsOneWidget);
    });
  });
}
