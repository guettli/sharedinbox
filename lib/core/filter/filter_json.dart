/// JSON (de)serialization for [FilterGroup] / [FilterNode] trees.
///
/// Notification rules persist a filter expression in the
/// `notification_rules.expression_json` column. Saved searches and Sieve rules
/// hold a [FilterGroup] in memory / as Sieve text; this codec gives the same
/// tree a stable on-disk JSON form so a rule survives app restarts and schema
/// migrations.
///
/// The wire format is intentionally small and forward-compatible:
/// ```json
/// {"op":"or","children":[
///   {"field":"from","cmp":"is","value":"alice@example.com"},
///   {"field":"subject","cmp":"contains","value":"urgent"}
/// ]}
/// ```
library;

import 'dart:convert';

import 'package:sharedinbox/core/filter/filter_expression.dart';

const _fieldToWire = {
  FilterField.from_: 'from',
  FilterField.to: 'to',
  FilterField.cc: 'cc',
  FilterField.subject: 'subject',
  FilterField.size: 'size',
  FilterField.header: 'header',
  FilterField.folder: 'folder',
};
final _wireToField = {
  for (final e in _fieldToWire.entries) e.value: e.key,
};

const _cmpToWire = {
  FilterComparison.contains: 'contains',
  FilterComparison.is_: 'is',
  FilterComparison.matches: 'matches',
  FilterComparison.over: 'over',
  FilterComparison.under: 'under',
};
final _wireToCmp = {
  for (final e in _cmpToWire.entries) e.value: e.key,
};

const _opToWire = {
  FilterOperator.and_: 'and',
  FilterOperator.or_: 'or',
};
final _wireToOp = {
  for (final e in _opToWire.entries) e.value: e.key,
};

Map<String, dynamic> filterNodeToMap(FilterNode node) {
  switch (node) {
    case FilterGroup():
      return {
        'op': _opToWire[node.operator],
        'children': node.children.map(filterNodeToMap).toList(),
      };
    case FilterLeaf():
      return {
        'field': _fieldToWire[node.field],
        'cmp': _cmpToWire[node.comparison],
        'value': node.value,
        if (node.headerName != null) 'header': node.headerName,
      };
  }
}

FilterNode filterNodeFromMap(Map<String, dynamic> map) {
  if (map.containsKey('op') || map.containsKey('children')) {
    final children = (map['children'] as List<dynamic>? ?? const [])
        .map((c) => filterNodeFromMap((c as Map).cast<String, dynamic>()))
        .toList();
    return FilterGroup(
      operator: _wireToOp[map['op']] ?? FilterOperator.and_,
      children: children,
    );
  }
  return FilterLeaf(
    field: _wireToField[map['field']] ?? FilterField.subject,
    comparison: _wireToCmp[map['cmp']] ?? FilterComparison.contains,
    value: map['value'] as String? ?? '',
    headerName: map['header'] as String?,
  );
}

/// Serializes a [FilterGroup] to a compact JSON string for storage.
String filterGroupToJson(FilterGroup group) =>
    jsonEncode(filterNodeToMap(group));

/// Parses a JSON string produced by [filterGroupToJson] back into a
/// [FilterGroup]. A malformed or non-group payload yields an empty group so a
/// corrupt rule degrades to "matches nothing" rather than crashing sync.
FilterGroup filterGroupFromJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) {
      final node = filterNodeFromMap(decoded);
      if (node is FilterGroup) return node;
    }
  } catch (_) {
    // Fall through to the empty group below.
  }
  return FilterGroup.empty();
}
