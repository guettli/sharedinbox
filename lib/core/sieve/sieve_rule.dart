import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';

class SieveRule {
  const SieveRule({
    required this.joinType,
    required this.conditions,
    required this.actions,
    this.branchGroupId,
    this.isElseBranch = false,
  });

  // 'allof', 'anyof', or 'single'
  final String joinType;
  final List<SieveCondition> conditions;
  final List<SieveAction> actions;
  // Non-null groups this rule into an if/elsif/else chain.
  final int? branchGroupId;
  // True for the unconditional else branch.
  final bool isElseBranch;
}
