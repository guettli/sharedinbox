import 'package:sharedinbox/core/filter/filter_expression.dart';

/// A single per-account "pop up for these mails" rule. Mail on the account
/// fires a notification when it matches **any** of the account's rules
/// (OR-combined). Persisted in the `notification_rules` Drift table with the
/// [filter] serialized to `expression_json`.
class NotificationRule {
  const NotificationRule({
    required this.id,
    required this.accountId,
    required this.filter,
    this.name,
    this.createdAt,
  });

  final int id;
  final String accountId;

  /// Optional human label. When null the UI renders a summary of [filter].
  final String? name;

  final FilterGroup filter;
  final DateTime? createdAt;
}
