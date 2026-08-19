import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';

void main() {
  testWidgets('Next week trailing shows the weekday abbreviation',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SnoozePicker())),
    );

    final nextWeek = DateTime.now().add(const Duration(days: 7));
    final weekday = DateFormat('EEE').format(nextWeek);

    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Next week'),
        matching: find.byType(ListTile),
      ),
    );
    final trailing = tile.trailing as Text;

    expect(trailing.data, startsWith('$weekday, '));
    expect(
      trailing.data,
      DateFormat('EEE, MMM d, 08:00').format(nextWeek),
    );
  });
}
