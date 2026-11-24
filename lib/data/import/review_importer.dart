import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';

/// SQLite's default limit of host parameters is 999; stay well below.
const _chunk = 400;

/// Writes an imported review history (#1385) as `review-seg` segments in
/// the `personal` collection. Events already in `review_log` (same
/// `(accountId, deviceId, seq)`) are dropped first, so a re-import writes
/// nothing. The local put runs `ReviewLogProjector`, which stores the rows
/// and recomputes the schedules of their cards; the normal sync uploads
/// the segments. No device owns them (their head's `device` is the import
/// deviceId), so `ReviewUploader` never touches them. Throws
/// `NoWriteKeyException` while the account is locked.
class ReviewImporter {
  ReviewImporter(this.db, this.log, {this.maxEvents = 1000});

  final AppDatabase db;
  final MailObjectLog log;

  /// The most events per segment. Revlog ids are not consecutive, so the
  /// head has one `covers` range per event (about 40 B): 1 000 stay far
  /// below the 256 KiB of an eagerly fetched head.
  final int maxEvents;

  /// Imports [events] of [deviceId]. Returns how many were written and how
  /// many were known already.
  Future<({int added, int known})> importReviews(
    String accountId,
    String deviceId,
    List<ReviewEvent> events,
  ) async {
    final bySeq = {for (final e in events) e.seq: e};
    final seqs = bySeq.keys.toList();
    final known = <int>{};
    for (var i = 0; i < seqs.length; i += _chunk) {
      known.addAll(
        await _knownSeqs(
          accountId,
          deviceId,
          seqs.sublist(i, (i + _chunk).clamp(0, seqs.length)),
        ),
      );
    }
    final fresh = [
      for (final e in bySeq.values)
        if (!known.contains(e.seq)) e,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    for (var i = 0; i < fresh.length; i += maxEvents) {
      final chunk = fresh.sublist(i, (i + maxEvents).clamp(0, fresh.length));
      await log.appendStamped(
        accountId,
        reviewLogName,
        personalCollectionId,
        [
          for (final e in chunk)
            LogEvent(seq: e.seq, hlc: Hlc.parse(e.h), json: e.toJson()),
        ],
        device: deviceId,
      );
    }
    return (added: fresh.length, known: known.length);
  }

  Future<Set<int>> _knownSeqs(
    String accountId,
    String deviceId,
    List<int> seqs,
  ) async =>
      (await (db.selectOnly(db.reviewLog)
                ..addColumns([db.reviewLog.seq])
                ..where(
                  db.reviewLog.accountId.equals(accountId) &
                      db.reviewLog.deviceId.equals(deviceId) &
                      db.reviewLog.seq.isIn(seqs),
                ))
              .map((r) => r.read(db.reviewLog.seq)!)
              .get())
          .toSet();
}
