import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/subject_normalize.dart';

/// Builds the [FilterGroup] that powers "Find similar emails" — matches every
/// message from the same primary sender whose normalised subject contains the
/// seed's normalised subject. Falls back to from-only when the subject is
/// empty after normalisation (e.g. seed has no subject), and to subject-only
/// when the seed has no `from` address.
FilterGroup similarFilterFor(Email seed) {
  final children = <FilterNode>[];

  if (seed.from.isNotEmpty) {
    children.add(
      FilterLeaf(
        field: FilterField.from_,
        comparison: FilterComparison.is_,
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
