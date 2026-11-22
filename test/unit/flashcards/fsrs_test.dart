import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';

import 'fake_time_zones.dart';

const _utc = FixedOffsetTimeZone(Duration.zero);
const _plus2 = FixedOffsetTimeZone(Duration(hours: 2));

int _ms(DateTime d) => d.millisecondsSinceEpoch;

/// Scheduler for the upstream reference vectors.
///
/// Upstream counts elapsed time in 24-hour periods (UTC); we count local
/// study days. With UTC, a day start of 00:00 and no fuzz, both agree for the
/// review times below (each review happens at the previous due time), so the
/// numbers are copied verbatim from dart-fsrs 2.0.1 / py-fsrs v6.
Fsrs _reference({
  List<Duration> learningSteps = const [
    Duration(minutes: 1),
    Duration(minutes: 10),
  ],
  List<Duration> relearningSteps = const [Duration(minutes: 10)],
  int maximumInterval = 36500,
}) =>
    Fsrs(
      params: FsrsParams(
        learningSteps: learningSteps,
        relearningSteps: relearningSteps,
        maximumInterval: maximumInterval,
        dayStartHour: 0,
        enableFuzz: false,
      ),
      tz: _utc,
    );

/// Interval of the last review in study days.
int _ivlDays(Fsrs fsrs, CardSchedule card) =>
    fsrs.dayOf(card.dueMs) - fsrs.dayOf(card.lastReviewMs!);

final _t0 = _ms(DateTime.utc(2022, 11, 29, 12, 30));

void main() {
  group('reference vectors (dart-fsrs / py-fsrs v6)', () {
    test('test_review_card', () {
      final fsrs = _reference();
      const ratings = [
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.again,
        Rating.again,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
      ];
      var card = CardSchedule.initial;
      var t = _t0;
      final ivlHistory = <int>[];
      for (final rating in ratings) {
        card = fsrs.review(card, rating, t);
        ivlHistory.add(_ivlDays(fsrs, card));
        t = card.dueMs;
      }
      expect(ivlHistory, [0, 4, 14, 45, 135, 372, 0, 0, 2, 5, 10, 20, 40]);
      expect(card.reps, ratings.length);
      expect(card.lapses, 1);
    });

    test('test_repeated_correct_reviews', () {
      final fsrs = _reference();
      var card = CardSchedule.initial;
      for (var i = 0; i < 10; i++) {
        card = fsrs.review(card, Rating.easy, _t0 + i);
      }
      expect(card.difficulty, 1.0);
    });

    test('test_memo_state', () {
      // Fuzz does not touch stability or difficulty, so it stays on here,
      // like upstream.
      final fsrs = Fsrs(params: FsrsParams(dayStartHour: 0), tz: _utc);
      const ratings = [
        Rating.again,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
        Rating.good,
      ];
      const ivlHistory = [0, 0, 1, 3, 8, 21];
      var card = CardSchedule.initial;
      var t = _t0;
      for (var i = 0; i < ratings.length; i++) {
        t += ivlHistory[i] * Duration.millisecondsPerDay;
        card = fsrs.review(card, ratings[i], t);
      }
      card = fsrs.review(card, Rating.good, t);
      expect(card.stability, closeTo(49.4472, 0.0001));
      expect(card.difficulty, closeTo(6.8271, 0.0001));
    });

    test('test_good_learning_steps', () {
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      expect(card.state, CardState.learning);
      expect(card.step, 1);
      expect(card.dueMs - _t0, const Duration(minutes: 10).inMilliseconds);

      card = fsrs.review(card, Rating.good, card.dueMs);
      expect(card.state, CardState.review);
      expect(card.step, isNull);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));
    });

    test('test_again_learning_steps', () {
      final fsrs = _reference();
      final card = fsrs.review(CardSchedule.initial, Rating.again, _t0);
      expect(card.state, CardState.learning);
      expect(card.step, 0);
      expect(card.dueMs - _t0, const Duration(minutes: 1).inMilliseconds);
    });

    test('test_hard_learning_steps', () {
      final fsrs = _reference();
      final card = fsrs.review(CardSchedule.initial, Rating.hard, _t0);
      expect(card.state, CardState.learning);
      expect(card.step, 0);
      expect(card.dueMs - _t0, const Duration(seconds: 330).inMilliseconds);
    });

    test('test_easy_learning_steps', () {
      final fsrs = _reference();
      final card = fsrs.review(CardSchedule.initial, Rating.easy, _t0);
      expect(card.state, CardState.review);
      expect(card.step, isNull);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));
    });

    test('test_review_state', () {
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      card = fsrs.review(card, Rating.good, card.dueMs);
      expect(card.state, CardState.review);
      expect(card.step, isNull);

      card = fsrs.review(card, Rating.good, card.dueMs);
      expect(card.state, CardState.review);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));

      final prevDue = card.dueMs;
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect(card.state, CardState.relearning);
      expect(card.dueMs - prevDue, const Duration(minutes: 10).inMilliseconds);
    });

    test('test_relearning', () {
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      card = fsrs.review(card, Rating.good, card.dueMs);
      card = fsrs.review(card, Rating.good, card.dueMs);

      var prevDue = card.dueMs;
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect(card.state, CardState.relearning);
      expect(card.step, 0);
      expect(card.dueMs - prevDue, const Duration(minutes: 10).inMilliseconds);

      prevDue = card.dueMs;
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect(card.state, CardState.relearning);
      expect(card.step, 0);
      expect(card.dueMs - prevDue, const Duration(minutes: 10).inMilliseconds);

      card = fsrs.review(card, Rating.good, card.dueMs);
      expect(card.state, CardState.review);
      expect(card.step, isNull);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));
    });

    test('test_no_learning_steps', () {
      final fsrs = _reference(learningSteps: const []);
      final card = fsrs.review(CardSchedule.initial, Rating.again, _t0);
      expect(card.state, CardState.review);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));
    });

    test('test_no_relearning_steps', () {
      final fsrs = _reference(relearningSteps: const []);
      var card = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      expect(card.state, CardState.learning);
      card = fsrs.review(card, Rating.good, card.dueMs);
      expect(card.state, CardState.review);
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect(card.state, CardState.review);
      expect(card.lapses, 1);
      expect(_ivlDays(fsrs, card), greaterThanOrEqualTo(1));
    });

    test('test_one_card_multiple_schedulers', () {
      final twoLearning = _reference();
      final oneLearning =
          _reference(learningSteps: const [Duration(minutes: 1)]);
      final noLearning = _reference(learningSteps: const []);
      final twoRelearning = _reference(
        relearningSteps: const [Duration(minutes: 1), Duration(minutes: 10)],
      );
      final oneRelearning =
          _reference(relearningSteps: const [Duration(minutes: 1)]);
      final noRelearning = _reference(relearningSteps: const []);

      var card = twoLearning.review(CardSchedule.initial, Rating.good, _t0);
      expect((card.state, card.step), (CardState.learning, 1));
      // Step 1 is past the end of a one-step list; Again still resets it.
      card = oneLearning.review(card, Rating.again, _t0);
      expect((card.state, card.step), (CardState.learning, 0));
      card = noLearning.review(card, Rating.hard, _t0);
      expect((card.state, card.step), (CardState.review, null));

      card = twoRelearning.review(card, Rating.again, _t0);
      expect((card.state, card.step), (CardState.relearning, 0));
      card = twoRelearning.review(card, Rating.good, _t0);
      expect((card.state, card.step), (CardState.relearning, 1));
      // Step 1 is past the end of a one-step list: Good, Hard or Easy
      // graduate the card.
      card = oneRelearning.review(card, Rating.hard, _t0);
      expect((card.state, card.step), (CardState.review, null));
      card = oneRelearning.review(card, Rating.again, _t0);
      expect((card.state, card.step), (CardState.relearning, 0));
      card = noRelearning.review(card, Rating.hard, _t0);
      expect((card.state, card.step), (CardState.review, null));
    });

    test('test_maximum_interval', () {
      const maximumInterval = 100;
      final fsrs = Fsrs(
        params: FsrsParams(maximumInterval: maximumInterval, dayStartHour: 0),
        tz: _utc,
      );
      var card = CardSchedule.initial;
      var t = _t0;
      for (final rating in [
        Rating.easy,
        Rating.good,
        Rating.easy,
        Rating.good,
      ]) {
        card = fsrs.review(card, rating, t, fuzzSeed: t);
        expect(_ivlDays(fsrs, card), lessThanOrEqualTo(maximumInterval));
        t = card.dueMs;
      }
    });

    test('test_stability_lower_bound', () {
      final fsrs = _reference();
      var card = CardSchedule.initial;
      for (var i = 0; i < 1000; i++) {
        card = fsrs.review(
          card,
          Rating.again,
          card.dueMs == 0 ? _t0 : card.dueMs + Duration.millisecondsPerDay,
        );
        expect(card.stability, greaterThanOrEqualTo(fsrsStabilityMin));
      }
    });

    test('test_learning_card_rate_hard_one_learning_step', () {
      final fsrs = _reference(learningSteps: const [Duration(minutes: 10)]);
      final card = fsrs.review(CardSchedule.initial, Rating.hard, _t0);
      expect(card.state, CardState.learning);
      expect(card.dueMs - _t0, const Duration(minutes: 15).inMilliseconds);
    });

    test('test_learning_card_rate_hard_second_learning_step', () {
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      expect((card.state, card.step), (CardState.learning, 1));
      final due1 = card.dueMs;
      card = fsrs.review(card, Rating.hard, due1);
      expect((card.state, card.step), (CardState.learning, 1));
      expect(card.dueMs - due1, const Duration(minutes: 10).inMilliseconds);
    });

    test('test_long_term_stability_learning_state', () {
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.easy, _t0);
      expect(card.state, CardState.review);
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect(card.state, CardState.relearning);
      card = fsrs.review(
        card,
        Rating.good,
        card.dueMs + Duration.millisecondsPerDay,
      );
      expect(card.state, CardState.review);
    });

    test('test_relearning_card_rate_hard_one_relearning_step', () {
      // The default relearning steps are a single 10-minute step.
      final fsrs = _reference();
      var card = fsrs.review(CardSchedule.initial, Rating.easy, _t0);
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect((card.state, card.step), (CardState.relearning, 0));
      final prevDue = card.dueMs;
      card = fsrs.review(card, Rating.hard, prevDue);
      expect((card.state, card.step), (CardState.relearning, 0));
      expect(card.dueMs - prevDue, const Duration(minutes: 15).inMilliseconds);
    });

    test('test_relearning_card_rate_hard_two_relearning_steps', () {
      final fsrs = _reference(
        relearningSteps: const [Duration(minutes: 1), Duration(minutes: 10)],
      );
      var card = fsrs.review(CardSchedule.initial, Rating.easy, _t0);
      card = fsrs.review(card, Rating.again, card.dueMs);
      expect((card.state, card.step), (CardState.relearning, 0));

      var prevDue = card.dueMs;
      card = fsrs.review(card, Rating.hard, prevDue);
      expect((card.state, card.step), (CardState.relearning, 0));
      expect(card.dueMs - prevDue, const Duration(seconds: 330).inMilliseconds);

      card = fsrs.review(card, Rating.good, card.dueMs);
      expect((card.state, card.step), (CardState.relearning, 1));

      prevDue = card.dueMs;
      card = fsrs.review(card, Rating.hard, prevDue);
      expect((card.state, card.step), (CardState.relearning, 1));
      expect(card.dueMs - prevDue, const Duration(minutes: 10).inMilliseconds);

      card = fsrs.review(card, Rating.easy, prevDue);
      expect((card.state, card.step), (CardState.review, null));
    });

    test('test_retrievability', () {
      final fsrs = _reference();
      var card = CardSchedule.initial;
      expect(fsrs.retrievability(card, _t0), 0);

      card = fsrs.review(card, Rating.good, _t0);
      expect(card.state, CardState.learning);
      expect(fsrs.retrievability(card, _t0), 1);

      card = fsrs.review(card, Rating.good, _t0);
      expect(card.state, CardState.review);
      final later = _t0 + 10 * Duration.millisecondsPerDay;
      expect(fsrs.retrievability(card, later), inExclusiveRange(0, 1));
      // A clock before the last review counts as no time elapsed.
      expect(
        fsrs.retrievability(card, _t0 - 2 * Duration.millisecondsPerDay),
        1,
      );
    });
  });

  group('FsrsParams', () {
    test('test_scheduler_parameter_validation', () {
      expect(FsrsParams(), isA<FsrsParams>());

      final oneTooHigh = List<double>.of(defaultFsrsWeights)..[6] = 100;
      expect(() => FsrsParams(weights: oneTooHigh), throwsArgumentError);

      final oneTooLow = List<double>.of(defaultFsrsWeights)..[10] = -42;
      expect(() => FsrsParams(weights: oneTooLow), throwsArgumentError);

      final twoBad = List<double>.of(defaultFsrsWeights)
        ..[0] = 0
        ..[3] = 101;
      expect(() => FsrsParams(weights: twoBad), throwsArgumentError);

      expect(() => FsrsParams(weights: const []), throwsArgumentError);
      expect(
        () => FsrsParams(
          weights: defaultFsrsWeights.sublist(0, defaultFsrsWeights.length - 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => FsrsParams(weights: [...defaultFsrsWeights, 1.0, 2.0, 3.0]),
        throwsArgumentError,
      );
    });

    test('rejects dayStartHour outside 0–23', () {
      expect(FsrsParams(dayStartHour: 0).dayStartHour, 0);
      expect(FsrsParams(dayStartHour: 23).dayStartHour, 23);
      expect(() => FsrsParams(dayStartHour: -1), throwsArgumentError);
      expect(() => FsrsParams(dayStartHour: 24), throwsArgumentError);
    });

    test('rejects invalid retention and maximum interval', () {
      expect(() => FsrsParams(desiredRetention: 0), throwsArgumentError);
      expect(() => FsrsParams(desiredRetention: 1), throwsArgumentError);
      expect(() => FsrsParams(maximumInterval: 0), throwsArgumentError);
    });

    test('defaults', () {
      final p = FsrsParams();
      expect(p.weights, defaultFsrsWeights);
      expect(p.desiredRetention, 0.9);
      expect(p.learningSteps, const [
        Duration(minutes: 1),
        Duration(minutes: 10),
      ]);
      expect(p.relearningSteps, const [Duration(minutes: 10)]);
      expect(p.maximumInterval, 36500);
      expect(p.dayStartHour, 4);
      expect(p.enableFuzz, isTrue);
    });

    test('copyWith and equality', () {
      final p = FsrsParams();
      expect(p, FsrsParams());
      expect(p.hashCode, FsrsParams().hashCode);
      expect(p.copyWith(), p);

      final weights = List<double>.of(defaultFsrsWeights)..[0] = 0.5;
      final changed = p.copyWith(
        weights: weights,
        desiredRetention: 0.85,
        learningSteps: const [Duration(minutes: 5)],
        relearningSteps: const [],
        maximumInterval: 365,
        dayStartHour: 0,
        enableFuzz: false,
      );
      expect(changed, isNot(p));
      expect(changed.weights, weights);
      expect(changed.desiredRetention, 0.85);
      expect(changed.learningSteps, const [Duration(minutes: 5)]);
      expect(changed.relearningSteps, isEmpty);
      expect(changed.maximumInterval, 365);
      expect(changed.dayStartHour, 0);
      expect(changed.enableFuzz, isFalse);
      expect(p.copyWith(dayStartHour: 5), isNot(p));
      expect(p.copyWith(learningSteps: const []), isNot(p));
    });

    test('weights are copied and unmodifiable', () {
      final weights = List<double>.of(defaultFsrsWeights);
      final p = FsrsParams(weights: weights);
      weights[0] = 0.5;
      expect(p.weights[0], defaultFsrsWeights[0]);
      expect(() => p.weights[0] = 0.5, throwsUnsupportedError);
    });

    test('a different desiredRetention or weights change the interval', () {
      Fsrs fsrs(FsrsParams p) => Fsrs(params: p, tz: _utc);
      final base = FsrsParams(enableFuzz: false, learningSteps: const []);
      int ivl(FsrsParams p) {
        final f = fsrs(p);
        return _ivlDays(f, f.review(CardSchedule.initial, Rating.easy, _t0));
      }

      final weights = List<double>.of(defaultFsrsWeights)..[3] = 30;
      expect(ivl(base), isNot(ivl(base.copyWith(desiredRetention: 0.8))));
      expect(ivl(base), isNot(ivl(base.copyWith(weights: weights))));
    });
  });

  group('Rating', () {
    test('fromValue', () {
      expect(Rating.fromValue(1), Rating.again);
      expect(Rating.fromValue(4), Rating.easy);
      expect(Rating.fromValue(0), isNull);
      expect(Rating.fromValue(5), isNull);
    });
  });

  group('CardSchedule', () {
    test('initial is a new card that is due now', () {
      const c = CardSchedule.initial;
      expect(c.state, CardState.newCard);
      expect(c.dueMs, 0);
      expect(c.lastReviewMs, isNull);
      expect(c.reps, 0);
      expect(c.lapses, 0);
    });

    test('equality and toString', () {
      final fsrs = _reference();
      final a = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      final b = fsrs.review(CardSchedule.initial, Rating.good, _t0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(CardSchedule.initial));
      expect(a.toString(), contains('CardState.learning'));
    });
  });

  group('fuzz', () {
    final fuzzy = Fsrs(
      params: FsrsParams(learningSteps: const [], dayStartHour: 0),
      tz: _utc,
    );
    final plain = Fsrs(
      params: FsrsParams(
        learningSteps: const [],
        dayStartHour: 0,
        enableFuzz: false,
      ),
      tz: _utc,
    );

    test('fuzz bounds match upstream', () {
      expect(fuzzy.fuzzBounds(3), (min: 2, max: 4));
      expect(fuzzy.fuzzBounds(16), (min: 13, max: 19));
      expect(fuzzy.fuzzBounds(100), (min: 93, max: 107));
    });

    test('fuzzed intervals stay inside the bounds and vary', () {
      final base =
          _ivlDays(plain, plain.review(CardSchedule.initial, Rating.easy, _t0));
      expect(base, 16);
      final bounds = fuzzy.fuzzBounds(base);
      final seen = <int>{};
      for (var seed = 0; seed < 200; seed++) {
        final card = fuzzy.review(
          CardSchedule.initial,
          Rating.easy,
          _t0,
          fuzzSeed: seed,
        );
        final ivl = _ivlDays(fuzzy, card);
        expect(ivl, inInclusiveRange(bounds.min, bounds.max));
        seen.add(ivl);
      }
      expect(seen.length, greaterThan(1));
      // Every day of the range is reachable.
      expect(seen, {for (var d = bounds.min; d <= bounds.max; d++) d});
    });

    test('the same seed gives the same due date', () {
      CardSchedule r() =>
          fuzzy.review(CardSchedule.initial, Rating.easy, _t0, fuzzSeed: 99);
      expect(r(), r());
    });

    test('intervals under 2.5 days are never fuzzed', () {
      for (final rating in [Rating.again, Rating.hard]) {
        final expected = plain.review(CardSchedule.initial, rating, _t0);
        expect(_ivlDays(plain, expected), lessThan(3));
        for (var seed = 0; seed < 100; seed++) {
          expect(
            fuzzy.review(CardSchedule.initial, rating, _t0, fuzzSeed: seed),
            expected,
          );
        }
      }
    });

    test('fuzz never exceeds maximumInterval', () {
      final capped = Fsrs(
        params: FsrsParams(
          learningSteps: const [],
          dayStartHour: 0,
          maximumInterval: 5,
        ),
        tz: _utc,
      );
      for (var seed = 0; seed < 100; seed++) {
        final card = capped.review(
          CardSchedule.initial,
          Rating.easy,
          _t0,
          fuzzSeed: seed,
        );
        expect(_ivlDays(capped, card), lessThanOrEqualTo(5));
      }
    });
  });

  group('study days', () {
    final fsrs = Fsrs(params: FsrsParams(enableFuzz: false), tz: _plus2);
    int local(int d, int h, int m) =>
        _ms(DateTime.utc(2026, 5, d, h, m)) -
        const Duration(hours: 2).inMilliseconds;

    test('03:50 and 04:10 local are on different study days', () {
      expect(fsrs.dayOf(local(10, 4, 10)) - fsrs.dayOf(local(10, 3, 50)), 1);
    });

    test('23:50 and 00:10 local are on the same study day', () {
      expect(fsrs.dayOf(local(11, 0, 10)) - fsrs.dayOf(local(10, 23, 50)), 0);
    });

    test('with dayStartHour 0, 23:50 and 00:10 are on different days', () {
      final midnight = Fsrs(
        params: FsrsParams(dayStartHour: 0, enableFuzz: false),
        tz: _plus2,
      );
      expect(
        midnight.dayOf(local(11, 0, 10)) - midnight.dayOf(local(10, 23, 50)),
        1,
      );
    });

    test('a review across 04:00 uses the long-term formula', () {
      final first = fsrs.review(
        fsrs.review(CardSchedule.initial, Rating.good, local(9, 20, 0)),
        Rating.good,
        local(9, 20, 5),
      );
      expect(first.state, CardState.review);
      final sameDay = fsrs.review(first, Rating.good, local(10, 3, 50));
      final nextDay = fsrs.review(first, Rating.good, local(10, 4, 10));
      final nextDayLater = fsrs.review(first, Rating.good, local(10, 22, 0));
      expect(nextDay.stability, isNot(sameDay.stability));
      expect(nextDay.stability, nextDayLater.stability);
    });

    test('a review-state due date lands on local 04:00', () {
      final card = fsrs.review(
        fsrs.review(CardSchedule.initial, Rating.good, local(10, 23, 50)),
        Rating.good,
        local(11, 0, 1),
      );
      expect(card.state, CardState.review);
      final due = _plus2.toLocal(card.dueMs);
      expect((due.hour, due.minute), (4, 0));
      // The review at 00:01 belongs to study day May 10.
      expect(due.day, 10 + _ivlDays(fsrs, card));
    });

    test('startOfDay is the inverse of dayOf', () {
      final day = fsrs.dayOf(local(10, 12, 0));
      expect(fsrs.startOfDay(day), local(10, 4, 0));
      expect(fsrs.dayOf(fsrs.startOfDay(day)), day);
      expect(fsrs.dayOf(fsrs.startOfDay(day) - 1), day - 1);
    });

    test('a DST switch keeps due dates at local 04:00', () {
      // Central Europe, 2026-03-29: +01:00 becomes +02:00 at 01:00 UTC.
      final switchMs = _ms(DateTime.utc(2026, 3, 29, 1));
      final dst = SwitchingTimeZone(
        switchMs: switchMs,
        before: const Duration(hours: 1),
        after: const Duration(hours: 2),
      );
      final f = Fsrs(
        params: FsrsParams(enableFuzz: false, learningSteps: const []),
        tz: dst,
      );

      final firstDay = f.dayOf(_ms(DateTime.utc(2026, 3, 20, 12)));
      for (var day = firstDay; day < firstDay + 20; day++) {
        final start = f.startOfDay(day);
        final local = dst.toLocal(start);
        expect((local.hour, local.minute), (4, 0));
        expect(f.dayOf(start), day);
        expect(f.dayOf(start - 1), day - 1);
        expect(f.startOfDay(day + 1) > start, isTrue);
      }
      // The day of the switch is one hour short.
      final switchDay = f.dayOf(switchMs);
      expect(
        f.startOfDay(switchDay + 1) - f.startOfDay(switchDay),
        const Duration(hours: 23).inMilliseconds,
      );

      // Good on a new card: interval 3 days, crossing the switch.
      final reviewMs = _ms(DateTime.utc(2026, 3, 27, 11));
      final card = f.review(CardSchedule.initial, Rating.good, reviewMs);
      expect(card.state, CardState.review);
      expect(_ivlDays(f, card), 3);
      final due = dst.toLocal(card.dueMs);
      expect((due.month, due.day, due.hour, due.minute), (3, 30, 4, 0));
    });

    test('SystemLocalTimeZone round-trips local wall-clock fields', () {
      const tz = SystemLocalTimeZone();
      final ms = DateTime(2024, 6, 15, 10).millisecondsSinceEpoch;
      final local = tz.toLocal(ms);
      expect(
        (local.year, local.month, local.day, local.hour),
        (2024, 6, 15, 10),
      );
      expect(tz.fromLocal(2024, 6, 15, 10), ms);
    });
  });
}
