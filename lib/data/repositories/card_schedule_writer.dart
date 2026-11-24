import 'dart:async';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/flashcards/card_replay.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';

/// SQLite's default limit of host parameters is 999; stay well below.
const _chunk = 400;

/// Keeps the `card_schedule` cache (#1380) in step with the `review_log`:
/// the schedule of a card is the replay ([replayCard]) of its reviews and
/// the undos of them, with the effective params of its deck
/// ([effectiveFsrsParams]). A card without a counted review has no row.
class CardScheduleWriter {
  CardScheduleWriter(
    this.db, {
    this.tz = const SystemLocalTimeZone(),
    this.appLogger,
  });

  final AppDatabase db;
  final LocalTimeZone tz;
  final AppLogger? appLogger;

  /// Replays [cardIds] of [accountId] and stores their schedules.
  Future<void> recompute(String accountId, Iterable<String> cardIds) async {
    final ids = cardIds.toSet().toList();
    if (ids.isEmpty) return;
    final state = await effectiveDeviceStateOf(db, accountId);
    for (var i = 0; i < ids.length; i += _chunk) {
      await _recomputeChunk(
        accountId,
        ids.sublist(i, (i + _chunk).clamp(0, ids.length)),
        state,
      );
    }
  }

  /// Replays every reviewed card of [accountId] ([deckIds]: only those of
  /// these decks; null in it: the cards whose deck is not known here).
  Future<void> recomputeAll(String accountId, {Set<String?>? deckIds}) async {
    final rows = await db.customSelect(
      'SELECT DISTINCT r.card_id AS card_id, c.collection_id AS deck '
      'FROM review_log r LEFT JOIN cards c ON c.account_id = r.account_id '
      "AND c.card_id = r.card_id WHERE r.account_id = ? AND r.op = 'review' "
      'AND r.card_id IS NOT NULL',
      variables: [Variable.withString(accountId)],
      readsFrom: {db.reviewLog, db.cards},
    ).get();
    await recompute(accountId, [
      for (final r in rows)
        if (deckIds == null || deckIds.contains(r.read<String?>('deck')))
          r.read<String>('card_id'),
    ]);
  }

  /// Replays the decks of [accountId] whose effective params differ from
  /// the ones their schedules were computed with. Returns those decks.
  Future<Set<String?>> refreshParams(String accountId) async {
    final state = await effectiveDeviceStateOf(db, accountId);
    final rows = await db.customSelect(
      'SELECT DISTINCT s.params_key AS params_key, c.collection_id AS deck '
      'FROM card_schedule s LEFT JOIN cards c ON c.account_id = s.account_id '
      'AND c.card_id = s.card_id WHERE s.account_id = ?',
      variables: [Variable.withString(accountId)],
      readsFrom: {db.cardSchedules, db.cards},
    ).get();
    final stale = {
      for (final r in rows)
        if (paramsKeyOf(effectiveFsrsParams(state, r.read<String?>('deck'))) !=
            r.read<String>('params_key'))
          r.read<String?>('deck'),
    };
    if (stale.isNotEmpty) await recomputeAll(accountId, deckIds: stale);
    return stale;
  }

  /// Replays the affected decks whenever device state (`fsrs.params`,
  /// `deck.<deckId>.options`) of any account changes, and once at the
  /// start. Cancel the subscription to stop.
  StreamSubscription<void> watchParams() {
    var tail = Future<void>.value();
    return (db.selectOnly(db.mailObjectDeviceStates, distinct: true)
          ..addColumns([db.mailObjectDeviceStates.accountId]))
        .map((r) => r.read(db.mailObjectDeviceStates.accountId)!)
        .watch()
        .listen((accountIds) {
      tail = tail.then((_) async {
        for (final accountId in accountIds) {
          try {
            await refreshParams(accountId);
          } catch (e) {
            unawaited(
              appLogger?.warn(
                'review.params_replay_failed',
                'Could not replay the reviews after a params change',
                accountId: accountId,
                data: {'error': e.toString()},
              ),
            );
          }
        }
      });
    });
  }

  Future<void> _recomputeChunk(
    String accountId,
    List<String> ids,
    Map<String, Object?> state,
  ) async {
    final reviews = await (db.select(db.reviewLog)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.op.equals('review') &
                t.cardId.isIn(ids),
          ))
        .get();
    final undos = await _undosOf(accountId, ids);
    final decks = {
      for (final c in await (db.select(db.cards)
            ..where(
              (t) => t.accountId.equals(accountId) & t.cardId.isIn(ids),
            ))
          .get())
        c.cardId: c.collectionId,
    };
    final byCard = <String, List<CardEvent>>{};
    for (final r in reviews) {
      (byCard[r.cardId!] ??= []).add(cardEventOf(r));
    }
    final none = <String>[];
    final schedules = <CardSchedulesCompanion>[];
    for (final id in ids) {
      final events = byCard[id];
      if (events == null) {
        none.add(id);
        continue;
      }
      final params = effectiveFsrsParams(state, decks[id]);
      final schedule =
          replayCard(id, [...events, ...undos], params: params, tz: tz);
      if (schedule == CardSchedule.initial) {
        none.add(id);
        continue;
      }
      schedules.add(_companion(accountId, id, schedule, paramsKeyOf(params)));
    }
    await db.batch((b) {
      if (none.isNotEmpty) {
        b.deleteWhere(
          db.cardSchedules,
          (t) => t.accountId.equals(accountId) & t.cardId.isIn(none),
        );
      }
      b.insertAllOnConflictUpdate(db.cardSchedules, schedules);
    });
  }

  /// The undos of the reviews of [ids].
  Future<List<CardEvent>> _undosOf(String accountId, List<String> ids) async {
    final rows = await db.customSelect(
      'SELECT u.* FROM review_log u JOIN review_log r '
      'ON r.account_id = u.account_id AND r.device_id = u.ref_device_id '
      "AND r.seq = u.ref_seq WHERE u.account_id = ? AND u.op = 'undo' "
      'AND r.card_id IN (${List.filled(ids.length, '?').join(', ')})',
      variables: [
        Variable.withString(accountId),
        for (final id in ids) Variable.withString(id),
      ],
      readsFrom: {db.reviewLog},
    ).get();
    return [
      for (final r in rows) cardEventOf(db.reviewLog.map(r.data)),
    ];
  }

  static CardSchedulesCompanion _companion(
    String accountId,
    String cardId,
    CardSchedule s,
    String paramsKey,
  ) =>
      CardSchedulesCompanion.insert(
        accountId: accountId,
        cardId: cardId,
        state: s.state.name,
        step: Value(s.step),
        stability: Value(s.stability),
        difficulty: Value(s.difficulty),
        dueMs: s.dueMs,
        lastReviewMs: Value(s.lastReviewMs),
        reps: s.reps,
        lapses: s.lapses,
        paramsKey: paramsKey,
      );
}
