import 'package:sharedinbox/core/filter/filter_matcher.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/notification_rule_repository.dart';

/// Callback that actually surfaces one OS notification. Injected so the
/// dispatcher can be unit-tested without the platform plugin.
typedef ShowNotification = Future<void> Function({
  required String accountId,
  required String emailId,
  required String title,
  required String body,
});

/// Decides which newly-arrived messages should pop up and fires one
/// notification per match. Default behaviour is silent: an account only
/// notifies when its master switch is on **and** at least one rule matches.
class NotificationDispatcher {
  NotificationDispatcher({
    required NotificationRuleRepository rules,
    required AccountRepository accounts,
    required ShowNotification show,
  })  : _rules = rules,
        _accounts = accounts,
        _show = show;

  final NotificationRuleRepository _rules;
  final AccountRepository _accounts;
  final ShowNotification _show;

  /// Evaluates the account's rules against every inbox message not yet
  /// considered, firing a notification for each match. Safe (and cheap) to
  /// call after every sync cycle — it short-circuits when notifications are
  /// off or no rules exist.
  Future<void> dispatchForAccount(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null || !account.notificationsEnabled) return;

    final rules = await _rules.listRules(accountId);
    if (rules.isEmpty) return;

    final candidates = await _rules.unnotifiedInboxEmails(accountId);
    if (candidates.isEmpty) return;

    final consideredIds = <String>[];
    for (final email in candidates) {
      consideredIds.add(email.id);
      final message = matchableFromEmail(email);
      if (rules.any((r) => matchesFilter(r.filter, message))) {
        await _show(
          accountId: accountId,
          emailId: email.id,
          title: notificationTitle(email),
          body: notificationBody(email),
        );
      }
    }
    await _rules.markNotified(accountId, consideredIds);
  }
}

/// Builds the matcher input from a stored [Email]. Only envelope data plus the
/// handful of headers cached on the row are available at notification time.
MatchableMessage matchableFromEmail(Email email) {
  MatchAddress toMatch(EmailAddress a) =>
      MatchAddress(name: a.name ?? '', email: a.email);
  final headers = <String, String>{};
  final listUnsub = email.listUnsubscribeHeader;
  if (listUnsub != null && listUnsub.isNotEmpty) {
    headers['list-unsubscribe'] = listUnsub;
  }
  return MatchableMessage(
    from: email.from.map(toMatch).toList(),
    to: email.to.map(toMatch).toList(),
    cc: email.cc.map(toMatch).toList(),
    subject: email.subject ?? '',
    folder: email.mailboxPath,
    headers: headers,
  );
}

/// Notification title: the sender's display name, or their address when no
/// name is present.
String notificationTitle(Email email) {
  if (email.from.isNotEmpty) {
    final sender = email.from.first;
    final name = sender.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (sender.email.isNotEmpty) return sender.email;
  }
  return 'New mail';
}

/// Notification body: the subject line, or a placeholder when empty.
String notificationBody(Email email) {
  final subject = email.subject?.trim();
  if (subject != null && subject.isNotEmpty) return subject;
  return '(no subject)';
}
