import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/study_queue.dart';

import 'fake_time_zones.dart';

const _now = 1700000000000;
const _min = 60000;
const _day = 86400000;

CardSchedule _s(CardState state, int dueMs) => CardSchedule(
      state: state,
      step: state == CardState.review ? null : 0,
      stability: 1,
      difficulty: 5,
      dueMs: dueMs,
      lastReviewMs: _now - _min,
      reps: 1,
      lapses: 0,
    );

/// Rates the current card at [_now] so it is due at [dueMs] as [state].
String _rateCurrent(StudyQueue q, CardState state, int dueMs) {
  final id = q.current(_now)!;
  q.rated(id, _s(state, dueMs));
  return id;
}

void main() {
  test('learning due, then reviews due, then new, then learning ahead', () {
    final q = StudyQueue(newLeft: 20)
      ..mergeDue([
        ('ahead', _s(CardState.learning, _now + 5 * _min)),
        ('review', _s(CardState.review, _now - 2 * _min)),
        ('learn', _s(CardState.relearning, _now - _min)),
        ('later', _s(CardState.review, _now + 30 * _min)),
      ])
      ..mergeNew(['n1', 'n2']);

    expect(q.counts(_now), (newCards: 2, learning: 2, due: 1));
    final order = [
      for (var i = 0; i < 5; i++)
        _rateCurrent(q, CardState.review, _now + 2 * _day),
    ];
    expect(order, ['learn', 'review', 'n1', 'n2', 'ahead']);
    // A review due later is not due yet: done.
    expect(q.current(_now), isNull);
  });

  test('a learning card beyond the learn-ahead window ends the session', () {
    final due = _now + learnAhead.inMilliseconds + 1;
    final q = StudyQueue(newLeft: 20)
      ..mergeDue([('far', _s(CardState.learning, due))])
      ..mergeNew(const []);
    expect(q.current(_now), isNull);
    expect(q.nextLearningDue(), due);
    expect(q.current(_now + 1), 'far');
  });

  test('a card rated Again comes back once due or as learn-ahead', () {
    final q = StudyQueue(newLeft: 20)..mergeNew(['n1', 'n2']);
    expect(_rateCurrent(q, CardState.learning, _now + _min), 'n1');
    expect(q.current(_now), 'n2');
    expect(_rateCurrent(q, CardState.review, _now + _day), 'n2');
    // Nothing else left: n1 is shown early (learn-ahead).
    expect(q.current(_now), 'n1');
  });

  test('newPerDay caps the new cards; undo gives the budget back', () {
    final q = StudyQueue(newLeft: 2)..mergeNew(['n1', 'n2', 'n3']);
    expect(q.counts(_now).newCards, 2);
    _rateCurrent(q, CardState.review, _now + _day);
    _rateCurrent(q, CardState.review, _now + _day);
    expect(q.newLeft, 0);
    expect(q.counts(_now).newCards, 0);
    expect(q.current(_now), isNull);

    expect(q.undo(), 'n2');
    expect(q.newLeft, 1);
    expect(q.current(_now), 'n2');
    expect(q.scheduleOf('n2'), isNull);
  });

  test('undo is a stack and restores the schedule from before', () {
    final before = _s(CardState.review, _now - _min);
    final q = StudyQueue(newLeft: 20)
      ..mergeDue([('r1', before)])
      ..mergeNew(['n1']);
    expect(q.canUndo, isFalse);
    expect(q.undo(), isNull);
    _rateCurrent(q, CardState.review, _now + _day);
    _rateCurrent(q, CardState.review, _now + _day);
    expect(q.current(_now), isNull);

    expect(q.undo(), 'n1');
    expect(q.undo(), 'r1');
    expect(q.scheduleOf('r1'), before);
    expect(q.current(_now), 'r1');
    expect(q.canUndo, isFalse);
  });

  test('stream updates keep the current card and the session schedules', () {
    final q = StudyQueue(newLeft: 20)
      ..mergeDue([('r1', _s(CardState.review, _now - _min))])
      ..mergeNew(['n1']);
    expect(q.current(_now), 'r1');
    // A new card arrives: r1 stays current.
    q.mergeNew(['n0', 'n1']);
    expect(q.current(_now), 'r1');

    _rateCurrent(q, CardState.review, _now + _day);
    // The store still shows r1 due (its write is not seen yet): ignored.
    q.mergeDue([('r1', _s(CardState.review, _now - _min))]);
    expect(q.current(_now), 'n0');
    expect(q.counts(_now).due, 0);
  });

  test('a deleted card leaves the queue, even the current one', () {
    final q = StudyQueue(newLeft: 20)..mergeNew(['n1', 'n2']);
    expect(q.current(_now), 'n1');
    q.setLive({'n2'});
    expect(q.current(_now), 'n2');
    expect(q.counts(_now).newCards, 1);
  });

  test('intervalLabel: steps in minutes or hours, reviews in days', () {
    final fsrs = Fsrs(
      params: FsrsParams(enableFuzz: false),
      tz: const FixedOffsetTimeZone(Duration.zero),
    );
    String label(CardState state, int dueMs) =>
        intervalLabel(fsrs, _s(state, dueMs), _now);
    expect(label(CardState.learning, _now + _min), '1m');
    expect(label(CardState.learning, _now + 10 * _min), '10m');
    expect(label(CardState.relearning, _now + 3 * 60 * _min), '3h');
    expect(label(CardState.review, _now + 3 * _day), '3d');
    expect(label(CardState.review, _now + 90 * _day), '3.0mo');
  });
}
