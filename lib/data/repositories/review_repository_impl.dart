import 'dart:math' as math;

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';
import 'package:sharedinbox/core/flashcards/review_upload_scheduler.dart';
import 'package:sharedinbox/core/flashcards/study_queue.dart';
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
  Stream<List<String>> observeNew(String accountId, String deckId) {
    final s = _db.cardSchedules;
    final c = _db.cards;
    final query = _db.select(c).join([
      leftOuterJoin(
        s,
        s.accountId.equalsExp(c.accountId) & s.cardId.equalsExp(c.cardId),
      ),
    ])
      ..where(
        c.accountId.equals(accountId) &
            c.collectionId.equals(deckId) &
            c.deleted.equals(false) &
            s.cardId.isNull(),
      )
      ..orderBy([OrderingTerm.asc(c.h), OrderingTerm.asc(c.cardId)]);
    return query
        .watch()
        .map((rows) => [for (final r in rows) r.readTable(c).cardId]);
  }

  @override
  Stream<Map<String, DeckCounts>> observeDeckCounts(
    String accountId,
    int nowMs,
  ) =>
      _db
          .customSelect(
            'SELECT c.collection_id AS deck, '
            'SUM(CASE WHEN s.card_id IS NULL THEN 1 ELSE 0 END) AS fresh, '
            "SUM(CASE WHEN s.state IN ('learning', 'relearning') "
            'AND s.due_ms <= ? THEN 1 ELSE 0 END) AS learning, '
            "SUM(CASE WHEN s.state = 'review' AND s.due_ms <= ? "
            'THEN 1 ELSE 0 END) AS due '
            'FROM cards c LEFT JOIN card_schedule s '
            'ON s.account_id = c.account_id AND s.card_id = c.card_id '
            'WHERE c.account_id = ? AND c.deleted = 0 '
            'GROUP BY c.collection_id',
            variables: [
              Variable.withInt(nowMs + learnAhead.inMilliseconds),
              Variable.withInt(nowMs),
              Variable.withString(accountId),
            ],
            readsFrom: {_db.cards, _db.cardSchedules, _db.reviewLog},
          )
          .watch()
          .asyncMap((rows) async {
            final state = await effectiveDeviceStateOf(_db, accountId);
            final firsts = await _firstReviews(accountId, nowMs);
            return {
              for (final r in rows)
                r.read<String>('deck'): (
                  due: r.read<int>('due'),
                  learning: r.read<int>('learning'),
                  newCards: math.min(
                    r.read<int>('fresh'),
                    _newLeft(state, r.read<String>('deck'), firsts, nowMs),
                  ),
                ),
            };
          });

  @override
  Future<FsrsParams> deckParams(String accountId, String deckId) async =>
      effectiveFsrsParams(await effectiveDeviceStateOf(_db, accountId), deckId);

  @override
  Future<int> newLeftToday(String accountId, String deckId) async {
    final nowMs = _now().millisecondsSinceEpoch;
    return _newLeft(
      await effectiveDeviceStateOf(_db, accountId),
      deckId,
      await _firstReviews(accountId, nowMs, deckId: deckId),
      nowMs,
    );
  }

  /// `newPerDay` of [deckId] less its cards whose first counted review in
  /// [firsts] is in the study day of [nowMs]; never below 0.
  int _newLeft(
    Map<String, Object?> state,
    String deckId,
    Map<String, List<int>> firsts,
    int nowMs,
  ) {
    final fsrs = Fsrs(
      params: effectiveFsrsParams(state, deckId),
      tz: _schedules.tz,
    );
    final dayStart = fsrs.startOfDay(fsrs.dayOf(nowMs));
    final studied = (firsts[deckId] ?? const []).where((t) => t >= dayStart);
    final perDay = DeckOptions.of(state, deckId).newPerDay;
    return math.max(0, perDay - studied.length);
  }

  /// Per deck the time of the first counted (not undone) review of each of
  /// its cards, for the cards first reviewed in the two days before
  /// [nowMs]: a study day starts at most that long before.
  Future<Map<String, List<int>>> _firstReviews(
    String accountId,
    int nowMs, {
    String? deckId,
  }) async {
    final rows = await _db.customSelect(
      'SELECT c.collection_id AS deck, MIN(r.t) AS first_t '
      'FROM review_log r JOIN cards c '
      'ON c.account_id = r.account_id AND c.card_id = r.card_id '
      "WHERE r.account_id = ? AND r.op = 'review' AND r.t IS NOT NULL "
      '${deckId == null ? '' : 'AND c.collection_id = ? '}'
      'AND NOT EXISTS (SELECT 1 FROM review_log u '
      "WHERE u.account_id = r.account_id AND u.op = 'undo' "
      'AND u.ref_device_id = r.device_id AND u.ref_seq = r.seq) '
      'GROUP BY c.collection_id, r.card_id HAVING MIN(r.t) >= ?',
      variables: [
        Variable.withString(accountId),
        if (deckId != null) Variable.withString(deckId),
        Variable.withInt(nowMs - const Duration(days: 2).inMilliseconds),
      ],
      readsFrom: {_db.reviewLog, _db.cards},
    ).get();
    final firsts = <String, List<int>>{};
    for (final r in rows) {
      (firsts[r.read<String>('deck')] ??= []).add(r.read<int>('first_t'));
    }
    return firsts;
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
