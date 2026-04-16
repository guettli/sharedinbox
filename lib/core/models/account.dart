/// Represents a configured IMAP/SMTP account stored in the local DB.
class Account {
  final String id;
  final String displayName;
  final String email;
  final String imapHost;
  final int imapPort;
  final bool imapSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpSsl;

  const Account({
    required this.id,
    required this.displayName,
    required this.email,
    required this.imapHost,
    required this.imapPort,
    required this.imapSsl,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSsl,
  });
}
