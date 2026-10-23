import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/accessible_dropdown.dart';

const _items = [
  DropdownMenuItem(value: 1, child: Text('One')),
  DropdownMenuItem(value: 2, child: Text('Two')),
];

/// Pumps [dropdown] and checks the enabled state its button node announces.
Future<void> _expectEnabled(
  WidgetTester tester,
  Widget dropdown,
  Type type, {
  required bool enabled,
}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: dropdown)));
  expect(
    tester.getSemantics(find.byType(type)),
    isSemantics(
      isButton: true,
      hasEnabledState: true,
      isEnabled: enabled,
    ),
  );
}

void main() {
  group('AccessibleDropdown', () {
    testWidgets('a usable dropdown announces as enabled', (tester) async {
      await _expectEnabled(
        tester,
        AccessibleDropdown(
          child: DropdownButton<int>(
            value: 1,
            items: _items,
            onChanged: (_) {},
          ),
        ),
        DropdownButton<int>,
        enabled: true,
      );
    });

    testWidgets('a dropdown without onChanged stays disabled', (tester) async {
      await _expectEnabled(
        tester,
        AccessibleDropdown(
          child: DropdownButton<int>(value: 1, items: _items, onChanged: null),
        ),
        DropdownButton<int>,
        enabled: false,
      );
    });

    testWidgets('a dropdown without items stays disabled', (tester) async {
      await _expectEnabled(
        tester,
        AccessibleDropdown(
          child: DropdownButton<int>(items: const [], onChanged: (_) {}),
        ),
        DropdownButton<int>,
        enabled: false,
      );
    });

    for (final enabled in [true, false]) {
      testWidgets('a form field with enabled=$enabled follows its onChanged', (
        tester,
      ) async {
        await _expectEnabled(
          tester,
          AccessibleDropdown.formField(
            child: DropdownButtonFormField<int>(
              initialValue: 1,
              decoration: const InputDecoration(labelText: 'Pick'),
              items: _items,
              onChanged: enabled ? (_) {} : null,
            ),
          ),
          DropdownButtonFormField<int>,
          enabled: enabled,
        );
      });
    }
  });
}
