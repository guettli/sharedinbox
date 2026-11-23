import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';

/// Writes the pending own reviews (`review_log` rows without a
/// `segmentItemId`) as `review-seg` segments in the `personal` collection
/// (#1380). The store's merge marks them through `ReviewLogProjector`, and
/// its sync uploads the segments. A crash after the local put leaves the
/// rows marked by the next merge of the segment or pending: a second
/// segment with the same events is harmless, readers dedupe by
/// `(deviceId, seq)`.
class ReviewUploader {
  ReviewUploader(this.db, this.log, {this.maxEvents = 1000});

  final AppDatabase db;
  final MailObjectLog log;

  /// The most events per segment; 1 000 stay far below the 200 KiB of gzip
  /// body of a segment.
  final int maxEvents;

  final Map<String, Future<void>> _tails = {};

  /// Writes the pending reviews of [accountId]; one flush per account at a
  /// time. Returns how many were written. Without a write key (locked)
  /// they stay pending.
  Future<int> flush(String accountId) {
    final run = (_tails[accountId] ?? Future<void>.value())
        .then((_) => _flush(accountId));
    _tails[accountId] = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// The accounts with pending reviews.
  Future<List<String>> pendingAccounts() =>
      (db.selectOnly(db.reviewLog, distinct: true)
            ..addColumns([db.reviewLog.accountId])
            ..where(db.reviewLog.segmentItemId.isNull()))
          .map((r) => r.read(db.reviewLog.accountId)!)
          .get();

  Future<int> _flush(String accountId) async {
    final clock = await log.store.clockFor(accountId);
    final rows = await (db.select(db.reviewLog)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.deviceId.equals(clock.deviceId) &
                t.segmentItemId.isNull(),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .get();
    var written = 0;
    for (var i = 0; i < rows.length; i += maxEvents) {
      final chunk = rows.sublist(i, (i + maxEvents).clamp(0, rows.length));
      try {
        await log
            .appendStamped(accountId, reviewLogName, personalCollectionId, [
          for (final r in chunk)
            LogEvent(
              seq: r.seq,
              hlc: Hlc.parse(r.h),
              json: cardEventOf(r).toJson(),
            ),
        ]);
      } on NoWriteKeyException {
        return written;
      }
      written += chunk.length;
    }
    return written;
  }
}
