import 'package:drift/drift.dart';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/data/db/database.dart';

/// The `review_log` row of [event] (#1380); [segmentItemId] null: own and
/// not uploaded yet.
ReviewLogCompanion reviewLogCompanion(
  String accountId,
  CardEvent event, {
  String? segmentItemId,
}) =>
    switch (event) {
      ReviewEvent() => ReviewLogCompanion.insert(
          accountId: accountId,
          deviceId: event.deviceId,
          seq: event.seq,
          op: 'review',
          h: event.h,
          cardId: Value(event.cardId),
          t: Value(event.t),
          rating: Value(event.rating),
          durationMs: Value(event.ms),
          segmentItemId: Value(segmentItemId),
        ),
      UndoEvent() => ReviewLogCompanion.insert(
          accountId: accountId,
          deviceId: event.deviceId,
          seq: event.seq,
          op: 'undo',
          h: event.h,
          refDeviceId: Value(event.refDeviceId),
          refSeq: Value(event.refSeq),
          segmentItemId: Value(segmentItemId),
        ),
    };

/// The [seqs] of [deviceId] already in `review_log`. Keep [seqs] below
/// SQLite's limit of 999 host parameters.
Future<Set<int>> knownReviewSeqs(
  AppDatabase db,
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

/// The event of a `review_log` row.
CardEvent cardEventOf(ReviewLogRow r) {
  if (r.op == 'undo') {
    return UndoEvent(
      deviceId: r.deviceId,
      seq: r.seq,
      h: r.h,
      refDeviceId: r.refDeviceId ?? '',
      refSeq: r.refSeq ?? 0,
    );
  }
  return ReviewEvent(
    deviceId: r.deviceId,
    seq: r.seq,
    h: r.h,
    cardId: r.cardId ?? '',
    t: r.t ?? 0,
    rating: r.rating ?? 0,
    ms: r.durationMs ?? 0,
  );
}

/// The [CardSchedule] of a `card_schedule` row.
CardSchedule cardScheduleOf(CardScheduleRow r) => CardSchedule(
      state: CardState.values.asNameMap()[r.state] ?? CardState.newCard,
      step: r.step,
      stability: r.stability,
      difficulty: r.difficulty,
      dueMs: r.dueMs,
      lastReviewMs: r.lastReviewMs,
      reps: r.reps,
      lapses: r.lapses,
    );
