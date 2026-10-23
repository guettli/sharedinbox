import 'package:sharedinbox/core/models/email.dart';

/// Ordered list of sibling emails threaded through to [EmailDetailScreen] via
/// Go Router's `extra`, so the detail screen can offer prev/next navigation
/// within the same source list (mailbox listing, search results, address
/// filter, …) instead of a global "next thread in this mailbox" (#292).
///
/// Each entry carries its own `accountId` + `mailboxPath` so that navigating
/// from a search result to its neighbour still builds a valid mailbox URL when
/// the neighbouring hit lives in a different folder or even a different
/// account.
class EmailDetailNav {
  const EmailDetailNav(this.items, {this.steppedTo = false});

  /// Flattens [threads] into one item per email so prev/next steps through
  /// individual messages, not threads.
  factory EmailDetailNav.fromThreads(List<EmailThread> threads) {
    return EmailDetailNav([
      for (final t in threads)
        for (final id in t.emailIds)
          EmailDetailNavItem(
            accountId: t.accountId,
            mailboxPath: t.mailboxPath,
            emailId: id,
          ),
    ]);
  }

  /// Wraps [emails] as one nav item per email, preserving order.
  factory EmailDetailNav.fromEmails(List<Email> emails) {
    return EmailDetailNav([
      for (final e in emails)
        EmailDetailNavItem(
          accountId: e.accountId,
          mailboxPath: e.mailboxPath,
          emailId: e.id,
        ),
    ]);
  }

  final List<EmailDetailNavItem> items;

  /// Set when the message was reached by stepping (prev/next, or the next
  /// message after an action) rather than opened by the user. Such a message
  /// stays in the detail view even when it is a draft, instead of jumping
  /// into compose mid-way through a list.
  final bool steppedTo;

  /// This list again, marked as reached by stepping.
  EmailDetailNav stepped() => EmailDetailNav(items, steppedTo: true);

  int indexOf(String emailId) => items.indexWhere((e) => e.emailId == emailId);

  EmailDetailNavItem? prevOf(String emailId) {
    final i = indexOf(emailId);
    if (i <= 0) return null;
    return items[i - 1];
  }

  EmailDetailNavItem? nextOf(String emailId) {
    final i = indexOf(emailId);
    if (i < 0 || i + 1 >= items.length) return null;
    return items[i + 1];
  }
}

class EmailDetailNavItem {
  const EmailDetailNavItem({
    required this.accountId,
    required this.mailboxPath,
    required this.emailId,
  });

  final String accountId;
  final String mailboxPath;
  final String emailId;
}
