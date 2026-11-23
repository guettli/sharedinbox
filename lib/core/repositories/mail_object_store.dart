import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/mail_object.dart';

/// The kind of a blob document (an image), referenced by its itemId
/// (ENCRYPTED-OBJECTS.md 5.4 item 3). Immutable: one version only.
const mailObjectBlobKind = 'blob';

/// The collection key of a `keyId` for [accountId], or null when this
/// device does not hold it (yet).
typedef CollectionKeyLookup = CollectionKey? Function(
  String accountId,
  Uint8List keyId,
);

/// The key new versions of [collectionId] are written with, or null.
typedef WriteKeyLookup = CollectionKey? Function(
  String accountId,
  String collectionId,
);

/// Whether the keys-folder mail [row], gone from the server, is uploaded
/// again (4.3). The key lifecycle keeps the mails of the key this device
/// holds and drops others, e.g. a race loser's or a replaced slot list.
typedef KeepVanishedKeyMail = Future<bool> Function(
  String accountId,
  MailObject row,
);

/// Keeps a projection table of one document [kind] (e.g. `Entries`) in step
/// with the merge (#1373). The store calls it inside the transaction that
/// writes an item's head columns, so the projection cannot diverge from the
/// merge: on a local write, a pull and a reopen after an unlock.
abstract interface class ObjectProjector {
  String get kind;

  /// Projects item [itemHmac]: [display] is its newest head that is not a
  /// tombstone, or null when the item is deleted (the row goes).
  /// [conflict]: it has several heads with different content.
  Future<void> apply(
    String accountId,
    String itemHmac,
    InnerObject? display, {
    required bool conflict,
  });
}

/// An item as the merge of its opened versions sees it.
class MailObjectItem {
  const MailObjectItem({
    required this.merge,
    required this.display,
    required this.versions,
  });

  final MergeResult merge;

  /// The opened head the UI shows ([MergeResult.display]); the base of the
  /// next `edit()` / `tombstone()`.
  final InnerObject display;

  /// One opened head per [MergeResult.distinctHeads], in the same order
  /// (oldest first): the versions of the conflict view.
  final List<InnerObject> versions;
}

/// Thrown by [MailObjectStore.put] when no write key for the collection is
/// available (no key unlocked on this device yet).
class NoWriteKeyException implements Exception {
  const NoWriteKeyException(this.collectionId);

  final String collectionId;

  @override
  String toString() => 'NoWriteKeyException: no key for "$collectionId"';
}

/// Thrown by [MailObjectStore.resolve] and [MailObjectStore.keepAll] when
/// the item is no longer in conflict or the kept version is no longer one of
/// its heads (a sync or another device got there first), and when a
/// deletion is to be kept next to an edit.
class ConflictChangedException implements Exception {
  const ConflictChangedException(this.message);

  final String message;

  @override
  String toString() => 'ConflictChangedException: $message';
}

/// The encrypted-object store on the mail server (ENCRYPTED-OBJECTS.md §3,
/// 5.4 Document, 5.5): mails in `SharedInbox/Keys` and `SharedInbox/Data`,
/// mirrored into the local DB. Every write is local first; [sync] pulls,
/// and in the foreground also pushes.
abstract class MailObjectStore {
  /// The local rows of [folder], without superseded versions.
  Stream<List<MailObject>> observe(String accountId, MailObjectFolder folder);

  /// Pulls both folders; in the foreground also uploads pending rows and
  /// deletes superseded versions on the server. A no-op for an account
  /// without recorded folders and without local rows.
  Future<void> sync(String accountId);

  /// Opens [object] with the known keys; null when its key is unknown, its
  /// body was not fetched, or it does not open.
  Future<InnerObject?> open(MailObject object);

  /// Tries again to open the rows no key could open so far (after an
  /// unlock) and merges them.
  Future<void> reopen(String accountId);

  /// The item [itemHmac], or null when none of its versions is opened.
  Future<MailObjectItem?> item(String accountId, String itemHmac);

  /// The HLC of this device for [accountId], advanced past every own
  /// version seen; versions passed to [put] take their `versionId` from it.
  Future<HlcClock> clockFor(String accountId);

  /// Seals [object] (a new item, or an `edit()` of [item]) and stores it to
  /// be uploaded. Versions its `parents` name become superseded.
  ///
  /// Throws [NoWriteKeyException], and [StateError] for a second version of
  /// a blob (blobs are immutable).
  Future<MailObject> put(String accountId, InnerObject object);

  /// Like [put] for a log pack (#1372): in the same transaction the rows
  /// [covered] (Message-IDs of the segments and packs it replaces) are
  /// hidden and marked to be deleted on the server, once the pack is
  /// confirmed there.
  Future<MailObject> putCovering(
    String accountId,
    InnerObject pack, {
    required List<String> covered,
  });

  /// The opened heads of [kind] that no pack covers, oldest first.
  Future<List<MailObject>> rowsOfKind(String accountId, String kind);

  /// The item HMAC of [itemId] in [collectionId], or null without a key for
  /// the collection.
  Future<String?> itemHmacOf(
    String accountId,
    String collectionId,
    String itemId,
  );

  /// Writes a tombstone over all heads of [itemHmac]. Throws [StateError]
  /// when the item is unknown.
  Future<MailObject> delete(String accountId, String itemHmac);

  /// The items in conflict of any kind (#1374), one per item.
  Stream<List<ConflictItem>> observeConflicts(String accountId);

  /// Resolves the conflict of [itemHmac] by keeping its distinct head
  /// [keep]: an edit of it (a tombstone if it is one) with
  /// `parents = all heads`. Throws [ConflictChangedException] when [keep] is
  /// no longer a distinct head of an item in conflict (another device
  /// resolved it).
  Future<MailObject> resolve(
    String accountId,
    String itemHmac, {
    required Hlc keep,
  });

  /// "Keep both": every other distinct head that is not a tombstone is
  /// copied into a new item ([forkObject]), then the conflict is resolved
  /// with [keep]. Throws [ConflictChangedException] when [keep] is a
  /// tombstone or no longer a distinct head.
  Future<void> keepAll(String accountId, String itemHmac, {required Hlc keep});

  /// Stores [mail] (an RFC 5322 mail with a Message-ID) in the keys folder,
  /// to be uploaded; idempotent by Message-ID.
  Future<MailObject> appendRaw(String accountId, Uint8List mail);

  /// Removes the keys-folder mail [messageId] from the server (foreground
  /// sync), then locally.
  Future<void> deleteRaw(String accountId, String messageId);

  /// Fetches the body of a row stored without it (over 256 KiB).
  Future<MailObject?> fetchBody(MailObject object);
}
