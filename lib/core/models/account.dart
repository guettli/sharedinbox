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

  // Used when type == AccountType.jmap
  final String? jmapUrl;

  const Account({
    required this.id,
    required this.displayName,
    required this.email,
    this.type = AccountType.imap,
    this.imapHost = '',
    this.imapPort = 993,
    this.imapSsl = true,
    this.smtpHost = '',
    this.smtpPort = 587,
    this.smtpSsl = false,
    this.jmapUrl,
  });
}
