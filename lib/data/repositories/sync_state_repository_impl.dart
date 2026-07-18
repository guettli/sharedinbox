import 'dart:convert';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/mailbox_sync_state.dart';
import 'package:sharedinbox/core/repositories/sync_state_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class SyncStateRepositoryImpl implements SyncStateRepository {
  SyncStateRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<List<MailboxSyncState>> statesForAccount(String accountId) async {
    final mailboxRows = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.accountId.equals(accountId)))
        .get();

    final emailRows = await (_db.select(
      _db.emails,
    )..where((t) => t.accountId.equals(accountId)))
        .get();

    final emailIdSubquery = _db.selectOnly(_db.emails)
      ..addColumns([_db.emails.id])
      ..where(_db.emails.accountId.equals(accountId));

    final bodyRows = await (_db.select(
      _db.emailBodies,
    )..where((t) => t.emailId.isInQuery(emailIdSubquery)))
        .get();
    final bodyByEmailId = {for (final b in bodyRows) b.emailId: b};

    final attachmentFileRows = await (_db.select(
      _db.attachmentFiles,
    )..where((t) => t.emailId.isInQuery(emailIdSubquery)))
        .get();
    final filesByEmailId = <String, List<AttachmentFileRow>>{};
    for (final f in attachmentFileRows) {
      (filesByEmailId[f.emailId] ??= []).add(f);
    }

    final buckets = <String, _MailboxBucket>{};
    for (final mb in mailboxRows) {
      buckets[mb.path] = _MailboxBucket();
    }

    for (final e in emailRows) {
      final bucket = buckets.putIfAbsent(e.mailboxPath, _MailboxBucket.new);
      final body = bodyByEmailId[e.id];
      if (body == null) {
        bucket.headerOnlyCount += 1;
        continue;
      }
      final bodyBytes = body.bodySize ?? 0;
      final downloadedFiles = filesByEmailId[e.id] ?? const [];
      final downloadedBytes = downloadedFiles.fold<int>(
        0,
        (sum, f) => sum + f.size,
      );

      if (!e.hasAttachment) {
        bucket.fullyOfflineCount += 1;
        bucket.fullyOfflineBytes += bodyBytes;
        continue;
      }

      final expected = _expectedAttachmentCount(body.attachmentsJson);
      final downloadedNames = downloadedFiles.map((f) => f.filename).toSet();
      if (expected == 0 || downloadedNames.length >= expected) {
        bucket.fullyOfflineCount += 1;
        bucket.fullyOfflineBytes += bodyBytes + downloadedBytes;
        continue;
      }
      bucket.partialCount += 1;
      bucket.partialBytes += bodyBytes + downloadedBytes;
    }

    // Sort known mailboxes by the normal folder-tree order.
    final sortedMailboxes = [...mailboxRows]
      ..sort((a, b) => compareMailboxes(_toMailbox(a), _toMailbox(b)));

    final result = <MailboxSyncState>[];
    for (final mb in sortedMailboxes) {
      final b = buckets[mb.path] ?? _MailboxBucket();
      final localCount =
          b.fullyOfflineCount + b.partialCount + b.headerOnlyCount;
      final serverOnly =
          mb.totalCount > localCount ? mb.totalCount - localCount : 0;
      final displayName = mb.displayPath.isNotEmpty ? mb.displayPath : mb.path;
      result.add(
        MailboxSyncState(
          mailboxPath: mb.path,
          displayName: displayName,
          fullyOfflineCount: b.fullyOfflineCount,
          fullyOfflineBytes: b.fullyOfflineBytes,
          partialCount: b.partialCount,
          partialBytes: b.partialBytes,
          headerOnlyCount: b.headerOnlyCount,
          serverOnlyCount: serverOnly,
        ),
      );
    }

    // Emails whose mailboxPath no longer matches a row in [mailboxes] — this
    // happens when a folder was renamed or dropped mid-sync. Append them at
    // the end (alphabetical) so the disk usage stays visible.
    final orphanPaths = buckets.keys
        .where((p) => !mailboxRows.any((mb) => mb.path == p))
        .toList()
      ..sort();
    for (final path in orphanPaths) {
      final b = buckets[path]!;
      result.add(
        MailboxSyncState(
          mailboxPath: path,
          displayName: path,
          fullyOfflineCount: b.fullyOfflineCount,
          fullyOfflineBytes: b.fullyOfflineBytes,
          partialCount: b.partialCount,
          partialBytes: b.partialBytes,
          headerOnlyCount: b.headerOnlyCount,
          serverOnlyCount: 0,
        ),
      );
    }

    return result;
  }

  int _expectedAttachmentCount(String attachmentsJson) {
    try {
      final decoded = jsonDecode(attachmentsJson);
      if (decoded is List) return decoded.length;
    } catch (_) {
      // Corrupt JSON — treat as no attachments so the mail still classifies
      // deterministically (fully offline if the body is cached).
    }
    return 0;
  }

  Mailbox _toMailbox(MailboxRow r) => Mailbox(
        id: r.id,
        accountId: r.accountId,
        path: r.path,
        name: r.name,
        unreadCount: r.unreadCount,
        totalCount: r.totalCount,
        displayPath: r.displayPath.isEmpty ? r.path : r.displayPath,
        parentId: r.parentId,
        role: r.role,
      );
}

class _MailboxBucket {
  int fullyOfflineCount = 0;
  int fullyOfflineBytes = 0;
  int partialCount = 0;
  int partialBytes = 0;
  int headerOnlyCount = 0;
}
