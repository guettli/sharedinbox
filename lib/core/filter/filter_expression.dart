enum FilterField {
  from_,
  to,
  cc,
  subject,
  size,
  header;

  String get label => switch (this) {
        FilterField.from_ => 'From',
        FilterField.to => 'To',
        FilterField.cc => 'CC',
        FilterField.subject => 'Subject',
        FilterField.size => 'Size (bytes)',
        FilterField.header => 'Header',
      };

  List<FilterComparison> get allowedComparisons => switch (this) {
        FilterField.size => [FilterComparison.over, FilterComparison.under],
        _ => [
            FilterComparison.contains,
            FilterComparison.is_,
            FilterComparison.matches,
          ],
      };
}

enum FilterComparison {
  contains,
  is_,
  matches,
  over,
  under;

  String get label => switch (this) {
        FilterComparison.contains => 'contains',
        FilterComparison.is_ => 'is',
        FilterComparison.matches => 'matches',
        FilterComparison.over => 'over',
        FilterComparison.under => 'under',
      };
}

enum FilterOperator { and_, or_ }

sealed class FilterNode {}

final class FilterLeaf extends FilterNode {
  FilterLeaf({
    required this.field,
    required this.comparison,
    required this.value,
    this.headerName,
  });

  final FilterField field;
  final FilterComparison comparison;
  final String value;

  /// Only meaningful when [field] is [FilterField.header] — names the raw
  /// mail header to match against (e.g. `List-Id`, `X-Spam-Status`).
  final String? headerName;

  FilterLeaf copyWith({
    FilterField? field,
    FilterComparison? comparison,
    String? value,
    String? headerName,
  }) =>
      FilterLeaf(
        field: field ?? this.field,
        comparison: comparison ?? this.comparison,
        value: value ?? this.value,
        headerName: headerName ?? this.headerName,
      );
}

final class FilterGroup extends FilterNode {
  FilterGroup({required this.operator, required this.children});

  final FilterOperator operator;
  final List<FilterNode> children;

  bool get isEmpty => children.isEmpty;

  FilterGroup copyWith({
    FilterOperator? operator,
    List<FilterNode>? children,
  }) =>
      FilterGroup(
        operator: operator ?? this.operator,
        children: children ?? this.children,
      );

  static FilterGroup empty() =>
      FilterGroup(operator: FilterOperator.and_, children: []);
}
