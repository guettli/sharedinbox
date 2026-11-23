import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart'
    show mailObjectEagerBodyLimit, mailObjectFromRow;

/// What the decrypted blob cache may hold per account, in decrypted bytes.
const blobCacheBudgetBytes = 100 * 1024 * 1024;

/// Blobs (images) over a [MailObjectStore] (#1372, 5.4 item 3): immutable
/// documents referenced by their itemId, with a local decrypted cache
/// ([MailObjectBlobs]). A blob over 256 KiB is downloaded on demand; once
/// the cache is over [budgetBytes], the least recently used blobs leave it,
/// and a confirmed blob over 256 KiB also drops its local ciphertext (the
/// next [blob] downloads it again).
class MailObjectBlobStore {
  MailObjectBlobStore(
    this.db,
    this.store, {
    this.budgetBytes = blobCacheBudgetBytes,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppDatabase db;
  final MailObjectStore store;
  final int budgetBytes;
  final DateTime Function() _now;

  /// Stores [bytes] as a new blob of [collectionId] and returns its itemId.
  /// Throws [ObjectTooLargeException] over 8 MiB (or a smaller JMAP
  /// `maxSizeUpload`), and `NoWriteKeyException`.
  Future<String> putBlob(
    String accountId,
    String collectionId,
    Uint8List bytes,
    String contentType,
  ) async {
    final itemId = newItemId();
    final clock = await store.clockFor(accountId);
    await store.put(
      accountId,
      InnerObject(
        head: ObjectHead(
          itemId: itemId,
          collectionId: collectionId,
          versionId: clock.send(),
          kind: mailObjectBlobKind,
        ),
        parts: [ObjectPart(contentType: contentType, bytes: bytes)],
      ),
    );
    await _cache(accountId, itemId, contentType, bytes);
    await evict(accountId);
    return itemId;
  }

  /// The bytes of blob [itemId] of [collectionId]: from the cache, else
  /// opened from the local row, downloaded first if its body is not here.
  /// Null when it is not known here or cannot be fetched now (offline): the
  /// UI shows a placeholder.
  Future<({String contentType, Uint8List bytes})?> blob(
    String accountId,
    String collectionId,
    String itemId,
  ) async {
    final cached = await _cached(accountId, itemId);
    if (cached != null) {
      await _touch(accountId, itemId);
      return (contentType: cached.contentType, bytes: cached.bytes);
    }
    final hmac = await store.itemHmacOf(accountId, collectionId, itemId);
    if (hmac == null) return null;
    var head = await _headRow(accountId, hmac);
    if (head == null) return null;
    if (head.payload == null) {
      try {
        head = await store.fetchBody(head);
      } catch (_) {
        // Offline or refused: a placeholder now, another try later.
        return null;
      }
      if (head == null || head.payload == null) return null;
    }
    final object = await store.open(head);
    final part = object?.parts.firstOrNull;
    if (object == null ||
        object.head.kind != mailObjectBlobKind ||
        object.head.itemId != itemId ||
        part == null) {
      return null;
    }
    await _cache(accountId, itemId, part.contentType, part.bytes);
    await evict(accountId);
    return (contentType: part.contentType, bytes: part.bytes);
  }

  /// Drops the least recently used blobs until the cache is within
  /// [budgetBytes]. Only blobs the server confirmed leave it; one over
  /// 256 KiB also loses its local ciphertext. Pending blobs stay.
  Future<void> evict(String accountId) async {
    final rows = await (db.select(db.mailObjectBlobs)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.lastUsedAt)]))
        .get();
    var total = rows.fold(0, (sum, r) => sum + r.sizeBytes);
    for (final r in rows) {
      if (total <= budgetBytes) return;
      final heads = await (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.itemId.equals(r.itemId) &
                  t.kind.equals(mailObjectBlobKind),
            ))
          .get();
      final confirmed = heads.isNotEmpty &&
          heads.every((h) => h.serverId != null && !h.pendingUpload);
      if (!confirmed) continue;
      await db.transaction(() async {
        await (db.delete(db.mailObjectBlobs)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) & t.itemId.equals(r.itemId),
              ))
            .go();
        for (final h in heads) {
          if (h.sizeBytes <= mailObjectEagerBodyLimit) continue;
          await (db.update(db.mailObjects)
                ..where(
                  (t) =>
                      t.accountId.equals(accountId) &
                      t.messageId.equals(h.messageId),
                ))
              .write(const MailObjectsCompanion(payload: Value(null)));
        }
      });
      total -= r.sizeBytes;
    }
  }

  Future<MailObject?> _headRow(String accountId, String itemHmac) async {
    final rows = await (db.select(db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(MailObjectFolder.data.name) &
                t.itemHmac.equals(itemHmac) &
                t.pendingDelete.equals(false),
          ))
        .get();
    return rows.isEmpty ? null : mailObjectFromRow(rows.first);
  }

  Future<MailObjectBlobRow?> _cached(String accountId, String itemId) =>
      (db.select(db.mailObjectBlobs)
            ..where(
              (t) => t.accountId.equals(accountId) & t.itemId.equals(itemId),
            ))
          .getSingleOrNull();

  Future<void> _cache(
    String accountId,
    String itemId,
    String contentType,
    Uint8List bytes,
  ) =>
      db.into(db.mailObjectBlobs).insertOnConflictUpdate(
            MailObjectBlobsCompanion.insert(
              accountId: accountId,
              itemId: itemId,
              contentType: contentType,
              bytes: bytes,
              sizeBytes: bytes.length,
              lastUsedAt: _now(),
            ),
          );

  Future<void> _touch(String accountId, String itemId) =>
      (db.update(db.mailObjectBlobs)
            ..where(
              (t) => t.accountId.equals(accountId) & t.itemId.equals(itemId),
            ))
          .write(MailObjectBlobsCompanion(lastUsedAt: Value(_now())));
}
