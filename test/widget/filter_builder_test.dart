import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';

Widget _harness(
  FilterGroup group,
  void Function(FilterGroup) onChanged, {
  Size size = const Size(800, 600),
  List<FilterField> fields = const [
    FilterField.from_,
    FilterField.to,
    FilterField.cc,
    FilterField.subject,
    FilterField.header,
  ],
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          child: FilterBuilderWidget(
            initialValue: group,
            onChanged: onChanged,
            // The Sieve rule editor omits the folder field, matching the
            // real screen; keep everything else the visual editor supports.
            availableFields: fields,
          ),
        ),
      ),
    ),
  );
}

FilterGroup _headerGroup() => FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.header,
          comparison: FilterComparison.contains,
          value: '',
          headerName: '',
        ),
      ],
    );

void main() {
  group('FilterBuilderWidget size leaf', () {
    testWidgets('shows an inline error once a typed size does not parse',
        (tester) async {
      FilterGroup? latest;
      await tester.pumpWidget(
        _harness(
          FilterGroup.single(FilterField.size, FilterComparison.over, ''),
          (g) => latest = g,
          fields: const [FilterField.subject, FilterField.size],
        ),
      );
      await tester.pumpAndSettle();
      // A fresh, empty condition is not flagged yet.
      expect(find.text(filterSizeHint), findsNothing);

      final value = find.byType(TextField);
      await tester.enterText(value, '1MB');
      await tester.pumpAndSettle();
      expect(find.text(filterSizeHint), findsNothing);
      expect(latest!.hasInvalidCondition, isFalse);

      await tester.enterText(value, 'Alice');
      await tester.pumpAndSettle();
      expect(find.text(filterSizeHint), findsOneWidget);
      expect(latest!.hasInvalidCondition, isTrue);

      // Cleared after typing: flagged now.
      await tester.enterText(value, '');
      await tester.pumpAndSettle();
      expect(find.text(filterSizeHint), findsOneWidget);
    });
  });

  group('FilterBuilderWidget header leaf', () {
    testWidgets('header name and value are both editable on a narrow width',
        (tester) async {
      FilterGroup? latest;
      await tester.pumpWidget(
        _harness(
          _headerGroup(),
          (g) => latest = g,
          size: const Size(360, 640),
        ),
      );
      await tester.pumpAndSettle();

      // Both inputs render (via their hints) without the row overflowing.
      expect(tester.takeException(), isNull);

      final headerNameField = find.widgetWithText(TextField, 'header name');
      final valueField = find.widgetWithText(TextField, 'value');
      expect(headerNameField, findsOneWidget);
      expect(valueField, findsOneWidget);

      await tester.enterText(headerNameField, 'List-Id');
      await tester.enterText(valueField, 'lists.example.com');
      await tester.pump();

      final leaf = latest!.children.single as FilterLeaf;
      expect(leaf.value, 'lists.example.com');
      expect(leaf.headerName, 'List-Id');
    });

    testWidgets('value field is editable on a wide width', (tester) async {
      FilterGroup? latest;
      await tester.pumpWidget(
        _harness(
          _headerGroup(),
          (g) => latest = g,
          size: const Size(900, 640),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      final valueField = find.widgetWithText(TextField, 'value');
      expect(valueField, findsOneWidget);

      await tester.enterText(valueField, 'newsletter');
      await tester.pump();

      expect((latest!.children.single as FilterLeaf).value, 'newsletter');
    });
  });
}
