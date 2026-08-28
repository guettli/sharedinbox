import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/notification_rule.dart';

/// Storage for per-account notification ("pop up for these mails") rules plus
/// the bookkeeping the [NotificationDispatcher] needs to fire each new message
/// at most once.
abstract class NotificationRuleRepository {
  /// Reactive list of rules for [accountId], newest first.
  Stream<List<NotificationRule>> watchRules(String accountId);

  Future<List<NotificationRule>> listRules(String accountId);

  /// Creates a rule and returns its new id.
  Future<int> addRule(String accountId, FilterGroup filter, {String? name});

  Future<void> updateRule(int id, FilterGroup filter, {String? name});

  Future<void> deleteRule(int id);

  /// Inbox messages on [accountId] that have not yet been considered for a
  /// notification, oldest first.
  Future<List<Email>> unnotifiedInboxEmails(String accountId);

  /// Records [emailIds] as already considered so they never notify again.
  Future<void> markNotified(String accountId, List<String> emailIds);

  /// Marks every inbox message currently on [accountId] as already notified.
  /// Called when the master switch is turned on so the existing backlog stays
  /// silent and only future arrivals pop up.
  Future<void> markBaseline(String accountId);
}
