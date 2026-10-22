enum FilterField {
  from_,
  to,
  cc,
  subject,
  size,
  header,
  folder;

  String get label => switch (this) {
        FilterField.from_ => 'From',
        FilterField.to => 'To',
        FilterField.cc => 'CC',
        FilterField.subject => 'Subject',
        FilterField.size => 'Size (bytes)',
        FilterField.header => 'Header',
        FilterField.folder => 'Folder',
      };

  List<FilterComparison> get allowedComparisons => switch (this) {
        FilterField.size => [FilterComparison.over, FilterComparison.under],
        // Folder is picked from the account's mailbox tree, so the only
        // meaningful comparison is an exact match against the stored path.
        FilterField.folder => [FilterComparison.is_],
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

  /// Why this condition cannot be evaluated as typed, or null when it can.
  /// Only a size condition can be invalid: its value must parse with
  /// [parseFilterSize], or it would silently match nothing (or, before, all).
  String? get validationError {
    if (field != FilterField.size) return null;
    return parseFilterSize(value) == null ? filterSizeHint : null;
  }

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

  /// True when some condition, at any depth, has a
  /// [FilterLeaf.validationError]; the editors then block Search / Save.
  bool get hasInvalidCondition => children.any(
        (c) => switch (c) {
          final FilterLeaf l => l.validationError != null,
          final FilterGroup g => g.hasInvalidCondition,
        },
      );

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

  /// A group holding one condition, the shape of a quick rule such as
  /// "From is <address>".
  static FilterGroup single(
    FilterField field,
    FilterComparison comparison,
    String value,
  ) =>
      FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(field: field, comparison: comparison, value: value),
        ],
      );
}

/// The inline error a size condition shows when its value does not parse.
const filterSizeHint = 'Enter a size in bytes, e.g. 50000, 10K or 1MB';

final _filterSizePattern =
    RegExp(r'^(\d+)\s*(?:([kmg])i?)?b?$', caseSensitive: false);

/// Parses the value of a [FilterField.size] condition into bytes: a whole
/// number, optionally followed by a K, M or G multiplier and/or a B, with or
/// without a space ("50000", "10k", "1M", "1MB", "1 MiB", "300 B").
///
/// The multipliers are binary (K = 1024), like Sieve's `size` test
/// (RFC 5228 §2.4.2.4), so a condition means the same in Advanced Search,
/// notification rules and a Sieve script. Returns null for anything else
/// (empty, negative, fractional, words), so callers never treat a typo as a
/// size.
int? parseFilterSize(String value) {
  final m = _filterSizePattern.firstMatch(value.trim());
  if (m == null) return null;
  final digits = m.group(1)!;
  // Keep to integers exact on every platform (2^53); no mail is that big.
  if (digits.length > 16) return null;
  final n = int.parse(digits);
  final multiplier = switch (m.group(2)?.toLowerCase()) {
    'k' => 1024,
    'm' => 1024 * 1024,
    'g' => 1024 * 1024 * 1024,
    _ => 1,
  };
  if (n > _maxFilterSize ~/ multiplier) return null;
  return n * multiplier;
}

const _maxFilterSize = 9007199254740992; // 2^53
