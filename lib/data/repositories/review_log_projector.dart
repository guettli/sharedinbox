import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/card_schedule_writer.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';

/// Writes the events of the `review` segments and packs into `review_log`
/// (#1380) and recomputes the schedules of the cards new events touch. Runs
/// inside the store's merge transaction ([LogProjector]), so an own event
/// is marked as uploaded (its `segmentItemId`) together with the local put
/// of its segment.
class ReviewLogProjector implements LogProjector {
  ReviewLogProjector(this.db, {CardScheduleWriter? schedules})
      : schedules = schedules ?? CardScheduleWriter(db);

  final AppDatabase db;
  final CardScheduleWriter schedules;

  @override
  String get log => reviewLogName;

  @override
  Future<void> apply(
    String accountId,
    String segmentItemId,
    List<LogEvent> events,
  ) async {
    final byDevice = <String, Map<int, CardEvent>>{};
    for (final e in events) {
      final event = CardEvent.fromLogEvent(e);
      if (event == null) continue;
      (byDevice[event.deviceId] ??= {})[event.seq] = event;
    }
    final fresh = <CardEvent>[];
    for (final MapEntry(key: deviceId, value: bySeq) in byDevice.entries) {
      final seqs = bySeq.keys.toList();
      for (var i = 0; i < seqs.length; i += 400) {
        final chunk = seqs.sublist(i, (i + 400).clamp(0, seqs.length));
        final known = await _knownSeqs(accountId, deviceId, chunk);
        fresh.addAll([
          for (final seq in chunk)
            if (!known.contains(seq)) bySeq[seq]!,
        ]);
        // Own events rated here: now in this segment.
        await (db.update(db.reviewLog)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.deviceId.equals(deviceId) &
                    t.seq.isIn(chunk) &
                    t.segmentItemId.isNull(),
              ))
            .write(ReviewLogCompanion(segmentItemId: Value(segmentItemId)));
      }
    }
    if (fresh.isEmpty) return;
    await db.batch(
      (b) => b.insertAll(
        db.reviewLog,
        [
          for (final e in fresh)
            reviewLogCompanion(accountId, e, segmentItemId: segmentItemId),
        ],
        mode: InsertMode.insertOrIgnore,
      ),
    );
    await schedules.recompute(accountId, await _cardsOf(accountId, fresh));
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

  /// The cards [events] change: of a review its card, of an undo the card
  /// of the review it cancels (none while that review is not here yet).
  Future<Set<String>> _cardsOf(
    String accountId,
    List<CardEvent> events,
  ) async {
    final cards = <String>{};
    for (final e in events) {
      switch (e) {
        case ReviewEvent(:final cardId):
          cards.add(cardId);
        case UndoEvent(:final refDeviceId, :final refSeq):
          final ref = await (db.select(db.reviewLog)
                ..where(
                  (t) =>
                      t.accountId.equals(accountId) &
                      t.deviceId.equals(refDeviceId) &
                      t.seq.equals(refSeq),
                ))
              .getSingleOrNull();
          if (ref?.cardId case final cardId?) cards.add(cardId);
      }
    }
    return cards;
  }
}
