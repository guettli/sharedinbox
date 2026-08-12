import 'package:flutter/material.dart';

// The label mapping lives in core so non-UI code (e.g. the account comparison)
// can render friendly folder names too; re-exported here for existing callers.
export 'package:sharedinbox/core/utils/mailbox_role_label.dart'
    show mailboxRoleLabel;

/// Presentation helpers for a mailbox [Mailbox.role].
///
/// Roles are the JMAP (RFC 8621) / IMAP special-use (RFC 6154) values such as
/// `inbox`, `sent`, `drafts`, `junk`, `trash`, `archive`, `snoozed`. Plain
/// user-created folders have a `null` role.

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
