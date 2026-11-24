import 'package:drift/drift.dart';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';
import 'package:sharedinbox/core/flashcards/review_upload_scheduler.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/review_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/card_schedule_writer.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';

/// [ReviewRepository] over `review_log` and `card_schedule` (#1380). An
/// event takes its `s` and `h` from the store's clock ([MailObjectStore.
/// clockFor]) and is stored pending (`segmentItemId` null); the
/// [ReviewUploadScheduler] is told how many are pending.
class ReviewRepositoryImpl implements ReviewRepository {
  ReviewRepositoryImpl(
    this._db,
    this._store, {
    required DeviceStateStore deviceState,
    CardScheduleWriter? schedules,
    ReviewUploadScheduler? uploads,
    DateTime Function()? now,
  })  : _deviceState = deviceState,
        _schedules = schedules ?? CardScheduleWriter(_db),
        _uploads = uploads,
        _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MailObjectStore _store;
  final DeviceStateStore _deviceState;
  final CardScheduleWriter _schedules;
  final ReviewUploadScheduler? _uploads;
  final DateTime Function() _now;

  @override
  Future<ReviewEvent> rate(
    String accountId,
    String cardId,
    Rating rating, {
    int durationMs = 0,
  }) async {
    final clock = await _store.clockFor(accountId);
    final event = await _db.transaction(() async {
      final event = ReviewEvent(
        deviceId: clock.deviceId,
        seq: clock.nextSeq(),
        h: clock.send().encode(),
        cardId: cardId,
        t: _now().millisecondsSinceEpoch,
        rating: rating.value,
        ms: durationMs,
      );
      await _db
          .into(_db.reviewLog)
          .insert(reviewLogCompanion(accountId, event));
      await _schedules.recompute(accountId, [cardId]);
      return event;
    });
    await _stored(accountId);
    return event;
  }

  @override
  Future<UndoEvent> undo(
    String accountId, {
    required String deviceId,
    required int seq,
  }) async {
    final clock = await _store.clockFor(accountId);
    final event = await _db.transaction(() async {
      final event = UndoEvent(
        deviceId: clock.deviceId,
        seq: clock.nextSeq(),
        h: clock.send().encode(),
        refDeviceId: deviceId,
        refSeq: seq,
      );
      await _db
          .into(_db.reviewLog)
          .insert(reviewLogCompanion(accountId, event));
      final ref = await (_db.select(_db.reviewLog)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.deviceId.equals(deviceId) &
                  t.seq.equals(seq),
            ))
          .getSingleOrNull();
      if (ref?.cardId case final cardId?) {
        await _schedules.recompute(accountId, [cardId]);
      }
      return event;
    });
    await _stored(accountId);
    return event;
  }

  @override
  Future<void> setParams(String accountId, FsrsParams params) =>
      _deviceState.set(accountId, fsrsParamsKey, fsrsParamsJson(params));

  @override
  Future<void> setDeckOptions(
    String accountId,
    String deckId,
    DeckOptions options,
  ) =>
      _deviceState.set(accountId, deckOptionsKey(deckId), options.toJson());

  @override
  Stream<CardSchedule?> observeSchedule(String accountId, String cardId) =>
      (_db.select(_db.cardSchedules)
            ..where(
              (t) => t.accountId.equals(accountId) & t.cardId.equals(cardId),
            ))
          .watchSingleOrNull()
          .map((r) => r == null ? null : cardScheduleOf(r));

  @override
  Stream<List<(String, CardSchedule)>> observeDue(
    String accountId,
    String deckId,
    int nowMs,
  ) {
    final s = _db.cardSchedules;
    final c = _db.cards;
    final query = _db.select(s).join([
      innerJoin(
        c,
        c.accountId.equalsExp(s.accountId) & c.cardId.equalsExp(s.cardId),
      ),
    ])
      ..where(
        s.accountId.equals(accountId) &
            c.collectionId.equals(deckId) &
            c.deleted.equals(false) &
            s.dueMs.isSmallerOrEqualValue(nowMs),
      )
      ..orderBy([OrderingTerm.asc(s.dueMs), OrderingTerm.asc(s.cardId)]);
    return query.watch().map(
          (rows) => [
            for (final r in rows)
              (r.readTable(s).cardId, cardScheduleOf(r.readTable(s))),
          ],
        );
  }

  @override
  void endSession(String accountId) => _uploads?.endSession(accountId);

  /// The own events of [accountId] not uploaded yet.
  Future<int> pendingCount(String accountId) async {
    final count = _db.reviewLog.seq.count();
    return (await (_db.selectOnly(_db.reviewLog)
              ..addColumns([count])
              ..where(
                _db.reviewLog.accountId.equals(accountId) &
                    _db.reviewLog.segmentItemId.isNull(),
              ))
            .map((r) => r.read(count))
            .getSingle()) ??
        0;
  }

  /// After an event was stored: the high-water marks (5.3) and the upload
  /// trigger.
  Future<void> _stored(String accountId) async {
    await _store.recordHighWater(accountId);
    final uploads = _uploads;
    if (uploads == null) return;
    uploads.rated(accountId, await pendingCount(accountId));
  }
}
