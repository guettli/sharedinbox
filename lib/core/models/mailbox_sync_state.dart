/// Per-mailbox breakdown of how much of the mailbox is available offline.
///
/// One mail can be in exactly one of these buckets per (account, mailbox):
///
/// - `serverOnly` — the server's [Mailbox.totalCount] exceeds the number of
///   local [Emails] rows. These messages have not been imported yet
///   (initial sync in progress, or interrupted). Byte size unknown.
/// - `headerOnly` — a row in [Emails] but no [EmailBodies] row. Metadata is
///   available offline; body and attachments are not.
/// - `partial` — [EmailBodies] cached but the mail has attachments and at
///   least one attachment is still missing from disk. Body bytes + any
///   downloaded attachment bytes are counted.
/// - `fullyOffline` — [EmailBodies] cached AND either the mail has no
///   attachments OR every attachment file is on disk. Complete offline copy.
class MailboxSyncState {
  const MailboxSyncState({
    required this.mailboxPath,
    required this.displayName,
    required this.fullyOfflineCount,
    required this.fullyOfflineBytes,
    required this.partialCount,
    required this.partialBytes,
    required this.headerOnlyCount,
    required this.serverOnlyCount,
  });

  /// Opaque server-side path. Same value as [Mailbox.path].
  final String mailboxPath;

  /// Human-readable label — [Mailbox.displayPath] if present, else path.
  final String displayName;

  final int fullyOfflineCount;
  final int fullyOfflineBytes;
  final int partialCount;
  final int partialBytes;
  final int headerOnlyCount;
  final int serverOnlyCount;

  int get localCount => fullyOfflineCount + partialCount + headerOnlyCount;
  int get totalCount => localCount + serverOnlyCount;
  int get totalBytes => fullyOfflineBytes + partialBytes;
}
