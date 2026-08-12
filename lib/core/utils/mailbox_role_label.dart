/// Human-readable label for a mailbox `role`.
///
/// Roles are the JMAP (RFC 8621) / IMAP special-use (RFC 6154) values such as
/// `inbox`, `sent`, `drafts`, `junk`, `trash`, `archive`, `snoozed`. Plain
/// user-created folders have a `null` role.
///
/// Returns `null` when the mailbox has no known role (user-created folders),
/// so callers can fall back to the raw folder name.
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
