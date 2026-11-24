import 'package:sharedinbox/core/encrypted_objects/entry_export.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';

/// [EntryExportService] over the entries projection, the store and the
/// blobs. Collects the entries of an unlocked account, every head of those in
/// conflict and their images, and builds the plaintext export
/// (ENCRYPTED-OBJECTS.md §6.1, #1356). Works offline: only an image whose
/// blob is not here is downloaded, and one that cannot be is listed in
/// `missingImages` instead.
class EntryExportServiceImpl implements EntryExportService {
  EntryExportServiceImpl(
    this._entries,
    this._store,
    this._blobs, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final EntryRepository _entries;
  final MailObjectStore _store;
  final MailObjectBlobStore _blobs;
  final DateTime Function() _now;

  @override
  Future<EntryExportResult> export(Account account) async {
    final accountId = account.id;
    final files = <ExportEntryFile>[];
    for (final entry in await _entries.allEntries(accountId)) {
      files.add(displayedExportFile(entry));
      if (!entry.hasConflict) continue;
      final item = await _store.item(accountId, entry.itemHmac);
      if (item == null) continue;
      for (final v in item.versions) {
        final versionId = v.head.versionId.encode();
        if (versionId == entry.versionId) continue;
        files.add(_conflictFile(v, accountId, entry.itemHmac));
      }
    }
    final ids = <String>{
      for (final f in files)
        if (f.entry != null) ...siImageIds(f.entry!.body),
    };
    final images = <String, ExportImage>{};
    final missing = <String>[];
    for (final id in ids) {
      final blob = await _blobs.blob(accountId, personalCollectionId, id);
      if (blob == null) {
        missing.add(id);
        continue;
      }
      images[id] = blob;
    }
    missing.sort();
    final exportedAt = _now();
    final zip = buildEntriesExport(
      account: account,
      files: files,
      images: images,
      missingImages: missing,
      exportedAt: exportedAt,
    );
    return (
      zip: zip,
      fileName: exportFileName(account, exportedAt),
      entries: files.where((f) => f.displayed).length,
      conflictVersions: files.where((f) => !f.displayed).length,
      images: images.length,
      missingImages: missing,
    );
  }

  /// A head of an item in conflict other than the displayed one; a
  /// tombstone (an edit racing a delete) becomes a `deleted` file.
  static ExportEntryFile _conflictFile(
    InnerObject v,
    String accountId,
    String itemHmac,
  ) {
    final entry = entryFromObject(
      v,
      accountId: accountId,
      itemHmac: itemHmac,
      conflict: true,
    );
    return (
      entry: entry,
      itemId: v.head.itemId,
      versionId: v.head.versionId.encode(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        v.head.versionId.wallMs,
        isUtc: true,
      ),
      conflict: true,
      deleted: v.head.deleted,
      displayed: false,
    );
  }
}
