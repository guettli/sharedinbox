import 'dart:math' as math;

import 'package:sharedinbox/core/flashcards/fsrs.dart';

/// Learning cards due within this window count as due: once nothing else is
/// left, one is shown early instead of ending the session (as in Anki).
const learnAhead = Duration(minutes: 20);

/// One rating of a session, as [StudyQueue.undo] puts it back.
class _Step {
  const _Step(this.cardId, this.previous);

  final String cardId;

  /// Its schedule before the rating; null for a new card.
  final CardSchedule? previous;
}

/// The cards of one study session of a deck (ENCRYPTED-OBJECTS.md §9,
/// #1381), all in memory, so the next card is ready without a DB round
/// trip. Pure: every method that depends on the time takes it.
///
/// Order: (re)learning cards due, then reviews due (earliest first), then
/// new cards in creation order up to [newLeft], then learning cards due
/// within [learnAhead]. A rated card keeps the schedule [rated] gave it for
/// the rest of the session, so a stream still showing the old one cannot
/// bring it back; it comes again once due.
class StudyQueue {
  StudyQueue({required int newLeft}) : _newLeft = newLeft;

  final _schedules = <String, CardSchedule>{};
  final _newIds = <String>[];
  final _touched = <String>{};
  final _undo = <_Step>[];
  Set<String>? _live;
  String? _current;
  int _newLeft;

  /// How many more new cards this session may show today.
  int get newLeft => _newLeft;

  bool get canUndo => _undo.isNotEmpty;

  /// The reviewed cards of the deck due soon, from the store. Cards rated in
  /// this session keep the schedule the session gave them.
  void mergeDue(Iterable<(String, CardSchedule)> due) {
    final fresh = {
      for (final (id, schedule) in due)
        if (!_touched.contains(id)) id: schedule,
    };
    _schedules
      ..removeWhere((id, _) => !_touched.contains(id) && !fresh.containsKey(id))
      ..addAll(fresh);
  }

  /// The new cards of the deck, in creation order, from the store.
  void mergeNew(Iterable<String> ids) {
    _newIds
      ..clear()
      ..addAll(ids.where((id) => !_touched.contains(id)));
  }

  /// The cards of the deck that are not deleted; null: all are.
  void setLive(Set<String>? live) => _live = live;

  /// The card to show at [nowMs], or null when nothing is left. Stays the
  /// same until it is rated or no longer in the deck.
  String? current(int nowMs) {
    final shown = _current;
    if (shown != null && _isQueued(shown)) return shown;
    return _current = _pick(nowMs);
  }

  /// The schedule of [cardId] in this session; null for a new card.
  CardSchedule? scheduleOf(String cardId) => _schedules[cardId];

  /// [cardId] was rated and is due again by [next].
  void rated(String cardId, CardSchedule next) {
    final previous = _schedules[cardId];
    _undo.add(_Step(cardId, previous));
    _touched.add(cardId);
    if (previous == null && _newIds.remove(cardId)) _newLeft--;
    _schedules[cardId] = next;
    if (_current == cardId) _current = null;
  }

  /// Takes back the last rating not taken back yet: its card is current
  /// again, with its schedule from before. Null when there is none.
  String? undo() {
    if (_undo.isEmpty) return null;
    final step = _undo.removeLast();
    final previous = step.previous;
    if (previous != null) {
      _schedules[step.cardId] = previous;
      return _current = step.cardId;
    }
    _schedules.remove(step.cardId);
    _newIds.insert(0, step.cardId);
    _newLeft++;
    return _current = step.cardId;
  }

  /// What is left at [nowMs]: new cards (up to [newLeft]), learning cards
  /// due within [learnAhead] and reviews due.
  ({int newCards, int learning, int due}) counts(int nowMs) {
    var learning = 0;
    var due = 0;
    for (final MapEntry(key: id, value: s) in _schedules.entries) {
      if (!_isLive(id)) continue;
      if (_isLearning(s) && s.dueMs <= nowMs + learnAhead.inMilliseconds) {
        learning++;
      }
      if (s.state == CardState.review && s.dueMs <= nowMs) due++;
    }
    final fresh = _newIds.where(_isLive).length;
    return (
      newCards: math.min(fresh, math.max(0, _newLeft)),
      learning: learning,
      due: due,
    );
  }

  /// When the next (re)learning card is due; null when there is none.
  int? nextLearningDue() {
    int? next;
    for (final MapEntry(key: id, value: s) in _schedules.entries) {
      if (!_isLive(id) || !_isLearning(s)) continue;
      if (next == null || s.dueMs < next) next = s.dueMs;
    }
    return next;
  }

  bool _isLive(String id) => _live?.contains(id) ?? true;

  bool _isQueued(String id) =>
      _isLive(id) && (_schedules.containsKey(id) || _newIds.contains(id));

  static bool _isLearning(CardSchedule s) =>
      s.state == CardState.learning || s.state == CardState.relearning;

  String? _pick(int nowMs) {
    String? earliest(bool Function(CardSchedule) take) {
      String? best;
      CardSchedule? bestSchedule;
      for (final MapEntry(key: id, value: s) in _schedules.entries) {
        if (!_isLive(id) || !take(s)) continue;
        final known = bestSchedule;
        if (known != null &&
            (s.dueMs > known.dueMs ||
                (s.dueMs == known.dueMs && id.compareTo(best!) > 0))) {
          continue;
        }
        best = id;
        bestSchedule = s;
      }
      return best;
    }

    final ahead = nowMs + learnAhead.inMilliseconds;
    return earliest((s) => _isLearning(s) && s.dueMs <= nowMs) ??
        earliest((s) => s.state == CardState.review && s.dueMs <= nowMs) ??
        (_newLeft > 0 ? _newIds.where(_isLive).firstOrNull : null) ??
        earliest((s) => _isLearning(s) && s.dueMs <= ahead);
  }
}

/// What a rating button shows (#1381): when [next] (the schedule a rating
/// at [nowMs] gives) is due. A learning step in minutes or hours, a review
/// in study days, months (30 days) or years.
String intervalLabel(Fsrs fsrs, CardSchedule next, int nowMs) {
  if (next.state != CardState.review) {
    final delay = Duration(milliseconds: math.max(0, next.dueMs - nowMs));
    if (delay < const Duration(hours: 1)) {
      return '${math.max(1, delay.inMinutes)}m';
    }
    if (delay < const Duration(days: 1)) return '${delay.inHours}h';
    return '${delay.inDays}d';
  }
  final days = math.max(1, fsrs.dayOf(next.dueMs) - fsrs.dayOf(nowMs));
  if (days < 30) return '${days}d';
  if (days < 365) return '${(days / 30).toStringAsFixed(1)}mo';
  return '${(days / 365).toStringAsFixed(1)}y';
}
