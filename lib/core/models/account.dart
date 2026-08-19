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

  /// Plain-text signature appended to outgoing messages composed from this
  /// account. Empty means no signature.
  final String signature;

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
    this.signature = '',
  });

  Account copyWith({
    String? id,
    String? displayName,
    String? email,
    String? username,
    AccountType? type,
    String? imapHost,
    int? imapPort,
    bool? imapSsl,
    String? smtpHost,
    int? smtpPort,
    bool? smtpSsl,
    String? manageSieveHost,
    int? manageSievePort,
    bool? manageSieveSsl,
    bool? manageSieveAvailable,
    String? jmapUrl,
    bool? verbose,
    String? signature,
  }) {
    return Account(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      username: username ?? this.username,
      type: type ?? this.type,
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      imapSsl: imapSsl ?? this.imapSsl,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpSsl: smtpSsl ?? this.smtpSsl,
      manageSieveHost: manageSieveHost ?? this.manageSieveHost,
      manageSievePort: manageSievePort ?? this.manageSievePort,
      manageSieveSsl: manageSieveSsl ?? this.manageSieveSsl,
      manageSieveAvailable: manageSieveAvailable ?? this.manageSieveAvailable,
      jmapUrl: jmapUrl ?? this.jmapUrl,
      verbose: verbose ?? this.verbose,
      signature: signature ?? this.signature,
    );
  }

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String,
      username: json['username'] as String? ?? '',
      type: AccountType.values.firstWhere(
        (e) => e.name == (json['type'] as String? ?? 'imap'),
        orElse: () => AccountType.imap,
      ),
      imapHost: json['imapHost'] as String? ?? '',
      imapPort: json['imapPort'] as int? ?? 993,
      imapSsl: json['imapSsl'] as bool? ?? true,
      smtpHost: json['smtpHost'] as String? ?? '',
      smtpPort: json['smtpPort'] as int? ?? 465,
      smtpSsl: json['smtpSsl'] as bool? ?? true,
      manageSieveHost: json['manageSieveHost'] as String? ?? '',
      manageSievePort: json['manageSievePort'] as int? ?? 4190,
      manageSieveSsl: json['manageSieveSsl'] as bool? ?? true,
      manageSieveAvailable: json['manageSieveAvailable'] as bool?,
      jmapUrl: json['jmapUrl'] as String?,
      verbose: json['verbose'] as bool? ?? false,
      signature: json['signature'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'email': email,
      'username': username,
      'type': type.name,
      'imapHost': imapHost,
      'imapPort': imapPort,
      'imapSsl': imapSsl,
      'smtpHost': smtpHost,
      'smtpPort': smtpPort,
      'smtpSsl': smtpSsl,
      'manageSieveHost': manageSieveHost,
      'manageSievePort': manageSievePort,
      'manageSieveSsl': manageSieveSsl,
      'manageSieveAvailable': manageSieveAvailable,
      'jmapUrl': jmapUrl,
      'verbose': verbose,
      'signature': signature,
    };
  }

  String get accountType => type.name;
}

/// Human-friendly label for an account. Prefers [Account.displayName], falls
/// back to [Account.email], and finally to [fallbackId] when the account can no
/// longer be resolved (e.g. it was removed after the row referencing it was
/// recorded). Never returns an empty string as long as [fallbackId] is set.
String accountDisplayLabel(Account? account, String fallbackId) {
  if (account == null) return fallbackId;
  if (account.displayName.isNotEmpty) return account.displayName;
  if (account.email.isNotEmpty) return account.email;
  return fallbackId;
}
