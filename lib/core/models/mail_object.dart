import 'dart:typed_data';

/// The two folders of the encrypted-object store (ENCRYPTED-OBJECTS.md §3).
enum MailObjectFolder {
  /// `SharedInbox/Keys`: key mails, stored raw and never opened here.
  keys,

  /// `SharedInbox/Data`: one mail per object version.
  data,
}

/// One mail of the encrypted-object store: a version of a document, or a
/// raw key mail. [payload] is the outer RFC 5322 mail (ciphertext); the
/// head fields are null until a key could open it.
class MailObject {
  const MailObject({
    required this.accountId,
    required this.folder,
    required this.messageId,
    this.itemHmac,
    this.itemId,
    this.versionId,
    this.parents = const [],
    this.kind,
    this.collectionId,
    this.serverId,
    this.sizeBytes = 0,
    this.pendingUpload = false,
    this.pendingDelete = false,
    this.conflictOf,
    this.payload,
  });

  final String accountId;
  final MailObjectFolder folder;

  /// The version's Message-ID, with angle brackets.
  final String messageId;

  /// `X-SharedInbox-Item` (base64url); null for a key mail.
  final String? itemHmac;
  final String? itemId;

  /// The encoded HLC of the version.
  final String? versionId;
  final List<String> parents;
  final String? kind;
  final String? collectionId;

  /// The IMAP UID; null until the server confirmed the mail.
  final String? serverId;
  final int sizeBytes;
  final bool pendingUpload;

  /// Superseded: removed from the server by the next foreground sync.
  final bool pendingDelete;

  /// Set on every head of an item in conflict: the versionId shown.
  final String? conflictOf;

  /// Null while a body over 256 KiB was not fetched yet.
  final Uint8List? payload;
}
