/// A mailbox / folder within an account (maps to an IMAP mailbox).
class Mailbox {
  final String id; // "<accountId>:<path>"
  final String accountId;

  /// Opaque server-side identifier for this mailbox.
  ///
  /// - IMAP: the hierarchical folder path (e.g. `INBOX/Work`), which the
  ///   server uses as its own reference. Same as [displayPath].
  /// - JMAP: the server-assigned mailbox ID (e.g. `a`), which is what
  ///   `Email` rows and JMAP requests reference. Not human-readable.
  ///
  /// This is what belongs in database foreign keys and protocol requests.
  final String path;

  /// Last path component / leaf name (e.g. `Work` for `INBOX/Work`).
  final String name;

  /// Hierarchical, human-readable path (e.g. `Archive/2026`).
  ///
  /// - IMAP: equal to [path].
  /// - JMAP: computed by walking the `parentId` chain and joining names
  ///   with `/`, so it always reads like a folder tree.
  ///
  /// This is what belongs in UI strings and in Sieve `fileinto`.
  final String displayPath;

  /// JMAP parent mailbox ID, or `null` for a root / for IMAP.
  final String? parentId;

  final int unreadCount;
  final int totalCount;
  // JMAP role (RFC 8621) or mapped from IMAP special-use (RFC 6154).
  // e.g. "inbox", "sent", "drafts", "junk", "trash", "archive"
  final String? role;

  const Mailbox({
    required this.id,
    required this.accountId,
    required this.path,
    required this.name,
    required this.unreadCount,
    required this.totalCount,
    String? displayPath,
    this.parentId,
    this.role,
  }) : displayPath = displayPath ?? path;

  Mailbox copyWith({
    String? id,
    String? accountId,
    String? path,
    String? name,
    String? displayPath,
    String? parentId,
    int? unreadCount,
    int? totalCount,
    String? role,
  }) {
    return Mailbox(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      path: path ?? this.path,
      name: name ?? this.name,
      displayPath: displayPath ?? this.displayPath,
      parentId: parentId ?? this.parentId,
      unreadCount: unreadCount ?? this.unreadCount,
      totalCount: totalCount ?? this.totalCount,
      role: role ?? this.role,
    );
  }

  factory Mailbox.fromJson(Map<String, dynamic> json) {
    return Mailbox(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      path: json['path'] as String,
      name: json['name'] as String,
      displayPath: json['displayPath'] as String?,
      parentId: json['parentId'] as String?,
      unreadCount: json['unreadCount'] as int,
      totalCount: json['totalCount'] as int,
      role: json['role'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'path': path,
      'name': name,
      'displayPath': displayPath,
      'parentId': parentId,
      'unreadCount': unreadCount,
      'totalCount': totalCount,
      'role': role,
    };
  }
}

/// Returns the human-readable path for [rawPath] from [mailboxes], falling
/// back to [rawPath] itself when the mailbox is not in the local cache (e.g.
/// deleted on the server since the row that stored [rawPath] was recorded).
///
/// For IMAP `path` and `displayPath` are equal. For JMAP `path` is the opaque
/// server id (e.g. `"a"`) whereas `displayPath` is a hierarchical name like
/// `"Archive/2026"`. Every UI that has an `Email` / `EmailThread` in hand (i.e.
/// only the raw `mailboxPath` string) must route it through this helper before
/// rendering to a user, otherwise the JMAP opaque id leaks into the UI (#288).
String resolveMailboxDisplayPath(List<Mailbox> mailboxes, String rawPath) {
  for (final m in mailboxes) {
    if (m.path == rawPath) return m.displayPath;
  }
  return rawPath;
}

/// Sorts mailboxes by role priority (Inbox first, etc) then alphabetically by
/// [Mailbox.displayPath], so JMAP mailboxes sort by their human-readable path
/// rather than by their opaque server ID.
int compareMailboxes(Mailbox a, Mailbox b) {
  const roleOrder = ['inbox', 'drafts', 'sent', 'archive', 'junk', 'trash'];
  final idxA = a.role == null ? 99 : roleOrder.indexOf(a.role!);
  final idxB = b.role == null ? 99 : roleOrder.indexOf(b.role!);
  final prioA = idxA == -1 ? 99 : idxA;
  final prioB = idxB == -1 ? 99 : idxB;

  if (prioA != prioB) {
    return prioA.compareTo(prioB);
  }
  return a.displayPath.toLowerCase().compareTo(b.displayPath.toLowerCase());
}
