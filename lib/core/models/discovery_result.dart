sealed class DiscoveryResult {}

final class JmapDiscovery extends DiscoveryResult {
  final String sessionUrl;
  JmapDiscovery({required this.sessionUrl});
}

final class ImapSmtpDiscovery extends DiscoveryResult {
  final String imapHost;
  final int imapPort;
  final bool imapSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpSsl;

  ImapSmtpDiscovery({
    required this.imapHost,
    required this.imapPort,
    required this.imapSsl,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSsl,
  });
}

final class UnknownDiscovery extends DiscoveryResult {}
