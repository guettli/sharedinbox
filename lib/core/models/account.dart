enum AccountType { imap, jmap }

class Account {
  final String id;
  final String displayName;
  final String email;
  final AccountType type;

  // Used when type == AccountType.imap
  final String imapHost;
  final int imapPort;
  final bool imapSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpSsl;

  /// ManageSieve host (RFC 5804). Empty falls back to [imapHost].
  /// Only consulted when [type] == AccountType.imap.
  final String manageSieveHost;
  final int manageSievePort;
  final bool manageSieveSsl;

  /// Tri-state result of the post-save ManageSieve probe.
  /// null  = not probed yet (treat as available; show UI),
  /// true  = probe succeeded,
  /// false = probe failed (hide ManageSieve UI for this account).
  final bool? manageSieveAvailable;

  // Used when type == AccountType.jmap
  final String? jmapUrl;

  /// Login username for IMAP/SMTP/JMAP. Empty means fall back to [email],
  /// then to the local part of [email] (the part before '@').
  final String username;

  /// When true, raw protocol traffic is captured and written to the sync log.
  /// Never enable in production — logs contain sensitive data even after
  /// credential redaction.
  final bool verbose;

  const Account({
    required this.id,
    required this.displayName,
    required this.email,
    this.username = '',
    this.type = AccountType.imap,
    this.imapHost = '',
    this.imapPort = 993,
    this.imapSsl = true,
    this.smtpHost = '',
    this.smtpPort = 465,
    this.smtpSsl = true,
    this.manageSieveHost = '',
    this.manageSievePort = 4190,
    this.manageSieveSsl = true,
    this.manageSieveAvailable,
    this.jmapUrl,
    this.verbose = false,
  });
}
