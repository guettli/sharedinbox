import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';

// Sunday evening, after "This evening" (18:00) has passed.
final _now = DateTime(2026, 10, 18, 22, 37);

/// Opens the picker in a bottom sheet, as the app does, and records what it
/// returns.
Future<List<DateTime?>> _openPicker(WidgetTester tester) async {
  final results = <DateTime?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await showModalBottomSheet<DateTime>(
                context: context,
                builder: (_) => SnoozePicker(now: _now),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('Next week is the same weekday next week at 08:00', (
    tester,
  ) async {
    final results = await _openPicker(tester);

    expect(find.text('Sun, Oct 25, 08:00'), findsOneWidget);
    await tester.tap(find.text('Next week'));
    await tester.pumpAndSettle();

    // Not 22:37, the time of day the picker was opened at.
    expect(results, [DateTime(2026, 10, 25, 8)]);
  });

  testWidgets('Tomorrow morning is 08:00 the next day', (tester) async {
    final results = await _openPicker(tester);

    expect(find.text('This evening'), findsNothing);
    await tester.tap(find.text('Tomorrow morning'));
    await tester.pumpAndSettle();

    expect(results, [DateTime(2026, 10, 19, 8)]);
  });

  testWidgets('a custom time that has passed asks again', (tester) async {
    final results = await _openPicker(tester);

    await tester.tap(find.text('Pick date & time…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // today
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // the default 08:00, already over
    await tester.pumpAndSettle();

    expect(find.text('That time has passed. Pick a later one'), findsOneWidget);
    expect(results, isEmpty);

    // The second ask offers 23:00, the next full hour, which is accepted.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(results, [DateTime(2026, 10, 18, 23)]);
  });

  testWidgets('Cancel on the second ask keeps the sheet open', (
    tester,
  ) async {
    final results = await _openPicker(tester);

    await tester.tap(find.text('Pick date & time…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.text('Next week'), findsOneWidget);
  });
}
