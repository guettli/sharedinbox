import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/subject_normalize.dart';

/// Builds the [FilterGroup] that powers "Find similar emails" — matches every
/// message whose `from` contains the seed's primary sender address and whose
/// normalised subject contains the seed's normalised subject. Falls back to
/// from-only when the subject is empty after normalisation (e.g. seed has no
/// subject), and to subject-only when the seed has no `from` address.
FilterGroup similarFilterFor(Email seed) {
  final children = <FilterNode>[];

  if (seed.from.isNotEmpty) {
    children.add(
      FilterLeaf(
        field: FilterField.from_,
        comparison: FilterComparison.contains,
        value: seed.from.first.email,
      ),
    );
  }

  final subj = normalizedSubject(seed.subject);
  if (subj.isNotEmpty) {
    children.add(
      FilterLeaf(
        field: FilterField.subject,
        comparison: FilterComparison.contains,
        value: subj,
      ),
    );
  }

  return FilterGroup(operator: FilterOperator.and_, children: children);
}

/// Builds the [FilterGroup] that powers "search all mail involving this sender"
/// — the from address of the opened mail matched with `contains` against
/// `from`, `to` and `cc`, OR-combined so any hop involving the address counts.
/// Returns an empty group when the seed has no `from` address, since a blank
/// `contains` would match every mail.
FilterGroup senderFilterFor(Email seed) {
  if (seed.from.isEmpty) {
    return FilterGroup.empty();
  }
  final addr = seed.from.first.email;
  return FilterGroup(
    operator: FilterOperator.or_,
    children: [
      for (final field in const [
        FilterField.from_,
        FilterField.to,
        FilterField.cc,
      ])
        FilterLeaf(
          field: field,
          comparison: FilterComparison.contains,
          value: addr,
        ),
    ],
  );
}
