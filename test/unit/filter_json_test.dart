import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_json.dart';

void main() {
  group('filter_json', () {
    test('round-trips a single-leaf group', () {
      final group = FilterGroup(
        operator: FilterOperator.or_,
        children: [
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.is_,
            value: 'alice@example.com',
          ),
        ],
      );

      final restored = filterGroupFromJson(filterGroupToJson(group));

      expect(restored.operator, FilterOperator.or_);
      expect(restored.children, hasLength(1));
      final leaf = restored.children.first as FilterLeaf;
      expect(leaf.field, FilterField.from_);
      expect(leaf.comparison, FilterComparison.is_);
      expect(leaf.value, 'alice@example.com');
    });

    test('round-trips nested groups and a header leaf', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'urgent',
          ),
          FilterGroup(
            operator: FilterOperator.or_,
            children: [
              FilterLeaf(
                field: FilterField.header,
                comparison: FilterComparison.matches,
                value: r'list\.example\.com',
                headerName: 'List-Id',
              ),
              FilterLeaf(
                field: FilterField.size,
                comparison: FilterComparison.over,
                value: '1000',
              ),
            ],
          ),
        ],
      );

      final restored = filterGroupFromJson(filterGroupToJson(group));

      expect(restored.operator, FilterOperator.and_);
      expect(restored.children, hasLength(2));
      final nested = restored.children[1] as FilterGroup;
      expect(nested.operator, FilterOperator.or_);
      final headerLeaf = nested.children.first as FilterLeaf;
      expect(headerLeaf.field, FilterField.header);
      expect(headerLeaf.headerName, 'List-Id');
      expect(headerLeaf.comparison, FilterComparison.matches);
      final sizeLeaf = nested.children[1] as FilterLeaf;
      expect(sizeLeaf.field, FilterField.size);
      expect(sizeLeaf.comparison, FilterComparison.over);
    });

    test('maps every field and comparison to a clean wire token', () {
      final map = filterNodeToMap(
        FilterLeaf(
          field: FilterField.from_,
          comparison: FilterComparison.is_,
          value: 'x',
        ),
      );
      // The enum name is `from_`; the wire form drops the underscore.
      expect(map['field'], 'from');
      expect(map['cmp'], 'is');
    });

    test('malformed JSON degrades to an empty group', () {
      expect(filterGroupFromJson('not json').isEmpty, isTrue);
      expect(filterGroupFromJson('[]').isEmpty, isTrue);
      expect(filterGroupFromJson('{"field":"from"}').isEmpty, isTrue);
    });
  });
}
