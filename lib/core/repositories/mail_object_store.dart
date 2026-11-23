import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/mail_object.dart';

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

/// An item as the merge of its opened versions sees it.
class MailObjectItem {
  const MailObjectItem({required this.merge, required this.display});

  final MergeResult merge;

  /// The opened head the UI shows ([MergeResult.display]); the base of the
  /// next `edit()` / `tombstone()`.
  final InnerObject display;
}

/// Thrown by [MailObjectStore.put] when no write key for the collection is
/// available (no key unlocked on this device yet).
class NoWriteKeyException implements Exception {
  const NoWriteKeyException(this.collectionId);

  final String collectionId;

  @override
  String toString() => 'NoWriteKeyException: no key for "$collectionId"';
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
  /// Throws [NoWriteKeyException].
  Future<MailObject> put(String accountId, InnerObject object);

  /// Writes a tombstone over all heads of [itemHmac]. Throws [StateError]
  /// when the item is unknown.
  Future<MailObject> delete(String accountId, String itemHmac);

  /// Stores [mail] (an RFC 5322 mail with a Message-ID) in the keys folder,
  /// to be uploaded; idempotent by Message-ID.
  Future<MailObject> appendRaw(String accountId, Uint8List mail);

  /// Removes the keys-folder mail [messageId] from the server (foreground
  /// sync), then locally.
  Future<void> deleteRaw(String accountId, String messageId);

  /// Fetches the body of a row stored without it (over 256 KiB).
  Future<MailObject?> fetchBody(MailObject object);
}
