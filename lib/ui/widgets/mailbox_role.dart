import 'package:flutter/material.dart';

/// Presentation helpers for a mailbox [Mailbox.role].
///
/// Roles are the JMAP (RFC 8621) / IMAP special-use (RFC 6154) values such as
/// `inbox`, `sent`, `drafts`, `junk`, `trash`, `archive`, `snoozed`. Plain
/// user-created folders have a `null` role.

/// Human-readable label for a mailbox [role] (e.g. `inbox` → "Inbox"), or
/// `null` when the mailbox has no known role (user-created folders).
String? mailboxRoleLabel(String? role) {
  switch (role) {
    case 'inbox':
      return 'Inbox';
    case 'sent':
      return 'Sent';
    case 'drafts':
      return 'Drafts';
    case 'junk':
      return 'Junk';
    case 'trash':
      return 'Trash';
    case 'archive':
      return 'Archive';
    case 'snoozed':
      return 'Snoozed';
    default:
      return null;
  }
}

/// Icon for a mailbox [role], falling back to a generic folder icon for
/// user-created folders (`null` / unknown role).
IconData mailboxRoleIcon(String? role) {
  switch (role) {
    case 'inbox':
      return Icons.inbox;
    case 'sent':
      return Icons.send;
    case 'drafts':
      return Icons.drafts;
    case 'junk':
      return Icons.report;
    case 'trash':
      return Icons.delete;
    case 'archive':
      return Icons.archive;
    case 'snoozed':
      return Icons.snooze;
    default:
      return Icons.folder;
  }
}
