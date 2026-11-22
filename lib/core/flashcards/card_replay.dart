import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/seeded_random.dart';

/// Derives the schedule of [cardId] by replaying its review log
/// (ENCRYPTED-OBJECTS.md, section 7). Pure: the result depends only on the
/// arguments, never on the order of [events] or the current time.
///
/// 1. Keeps reviews of [cardId] (with a rating of 1–4) and all undos.
/// 2. Dedupes by `(deviceId, seq)`, so overlapping packs count once.
/// 3. Drops reviews targeted by an undo; an undo of a missing event does
///    nothing.
/// 4. Sorts by `h`, then deviceId, then seq.
/// 5. Folds the reviews through [Fsrs.review]; the fuzz seed of each review is
///    FNV-1a of `"$cardId\u0000$h"`, so every device gets the same due dates.
///
/// A params change is simply another call with the new [params].
CardSchedule replayCard(
  String cardId,
  Iterable<CardEvent> events, {
  FsrsParams? params,
  LocalTimeZone tz = const SystemLocalTimeZone(),
}) {
  final fsrs = Fsrs(params: params, tz: tz);

  final byId = <(String, int), CardEvent>{};
  for (final event in events) {
    if (event is ReviewEvent && !_isReviewOf(event, cardId)) continue;
    final key = (event.deviceId, event.seq);
    final seen = byId[key];
    // Two different events with one id should not exist; if they do, keep a
    // deterministic one so the input order still does not matter.
    if (seen != null && _compareCanonical(seen, event) <= 0) continue;
    byId[key] = event;
  }

  final undone = {
    for (final event in byId.values)
      if (event is UndoEvent) (event.refDeviceId, event.refSeq),
  };

  final reviews = [
    for (final event in byId.values)
      if (event is ReviewEvent && !undone.contains((event.deviceId, event.seq)))
        event,
  ]..sort(_compareReplayOrder);

  var schedule = CardSchedule.initial;
  for (final event in reviews) {
    schedule = fsrs.review(
      schedule,
      Rating.fromValue(event.rating)!,
      event.t,
      fuzzSeed: fnv1a32('$cardId\u0000${event.h}'),
    );
  }
  return schedule;
}

bool _isReviewOf(ReviewEvent event, String cardId) =>
    event.cardId == cardId && Rating.fromValue(event.rating) != null;

int _compareReplayOrder(CardEvent a, CardEvent b) {
  final byH = a.h.compareTo(b.h);
  if (byH != 0) return byH;
  final byDevice = a.deviceId.compareTo(b.deviceId);
  if (byDevice != 0) return byDevice;
  return a.seq.compareTo(b.seq);
}

int _compareCanonical(CardEvent a, CardEvent b) =>
    a.toString().compareTo(b.toString());
