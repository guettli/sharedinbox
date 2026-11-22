// FSRS-6 spaced-repetition scheduler, pure Dart.
//
// The memory model (formulas, default weights, parameter bounds, fuzz ranges
// and the learning-step rules) is ported from the open-spaced-repetition
// `fsrs` Dart package 2.0.1 (a port of py-fsrs v6), MIT licence,
// https://github.com/open-spaced-repetition/dart-fsrs.
//
// Differences from upstream (see issue #1378):
// - Elapsed time counts local study days that start at `dayStartHour`
//   (default 04:00), not 24-hour periods in UTC.
// - Review-state cards are due at the start of a study day.
// - State is immutable and there is no clock: every review gets its time.
// - Fuzz draws from a [SeededRandom] seeded by the caller, so a replay gives
//   the same due dates on every device.

import 'dart:math' as math;

import 'package:sharedinbox/core/flashcards/seeded_random.dart';

enum Rating {
  again(1),
  hard(2),
  good(3),
  easy(4);

  const Rating(this.value);

  final int value;

  /// Returns the rating for [value], or null when it is not 1–4.
  static Rating? fromValue(int value) {
    for (final rating in Rating.values) {
      if (rating.value == value) return rating;
    }
    return null;
  }
}

enum CardState { newCard, learning, review, relearning }

/// FSRS-6 default weights (w0 … w20).
const defaultFsrsWeights = <double>[
  0.2172,
  1.1771,
  3.2602,
  16.1507,
  7.0114,
  0.57,
  2.0966,
  0.0069,
  1.5261,
  0.112,
  1.0178,
  1.849,
  0.1133,
  0.3127,
  2.2934,
  0.2191,
  3.0004,
  0.7536,
  0.3332,
  0.1437,
  0.2,
];

const fsrsStabilityMin = 0.001;
const _initialStabilityMax = 100.0;
const _minDifficulty = 1.0;
const _maxDifficulty = 10.0;

const _lowerBoundsWeights = <double>[
  fsrsStabilityMin,
  fsrsStabilityMin,
  fsrsStabilityMin,
  fsrsStabilityMin,
  1.0,
  0.001,
  0.001,
  0.001,
  0.0,
  0.0,
  0.001,
  0.001,
  0.001,
  0.001,
  0.0,
  0.0,
  1.0,
  0.0,
  0.0,
  0.0,
  0.1,
];

const _upperBoundsWeights = <double>[
  _initialStabilityMax,
  _initialStabilityMax,
  _initialStabilityMax,
  _initialStabilityMax,
  10.0,
  4.0,
  4.0,
  0.75,
  4.5,
  0.8,
  3.5,
  5.0,
  0.25,
  0.9,
  4.0,
  1.0,
  6.0,
  2.0,
  2.0,
  0.8,
  0.8,
];

/// Upstream fuzz ranges: an interval of `d` days may move by
/// `1 + sum(factor * max(min(d, end) - start, 0))` days.
const _fuzzRanges = <({double start, double end, double factor})>[
  (start: 2.5, end: 7.0, factor: 0.15),
  (start: 7.0, end: 20.0, factor: 0.1),
  (start: 20.0, end: double.infinity, factor: 0.05),
];

const _msPerDay = 86400000;

/// Scheduler parameters (deck options). Immutable; invalid values throw an
/// [ArgumentError] when constructed.
class FsrsParams {
  FsrsParams({
    List<double> weights = defaultFsrsWeights,
    this.desiredRetention = 0.9,
    this.learningSteps = const [Duration(minutes: 1), Duration(minutes: 10)],
    this.relearningSteps = const [Duration(minutes: 10)],
    this.maximumInterval = 36500,
    this.dayStartHour = 4,
    this.enableFuzz = true,
  }) : weights = List.unmodifiable(weights) {
    _validate();
  }

  /// The 21 FSRS-6 model weights.
  final List<double> weights;

  /// Target probability of recall when a review-state card becomes due.
  final double desiredRetention;

  /// Steps of a new or learning card before it moves to review.
  final List<Duration> learningSteps;

  /// Steps of a lapsed card before it moves back to review.
  final List<Duration> relearningSteps;

  /// Longest review interval in days.
  final int maximumInterval;

  /// Local hour (0–23) at which a study day starts.
  final int dayStartHour;

  /// Whether review intervals get a small deterministic random fuzz.
  final bool enableFuzz;

  void _validate() {
    if (weights.length != _lowerBoundsWeights.length) {
      throw ArgumentError(
        'Expected ${_lowerBoundsWeights.length} weights, got ${weights.length}.',
      );
    }
    final errors = <String>[];
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (_lowerBoundsWeights[i] <= w && w <= _upperBoundsWeights[i]) continue;
      errors.add(
        'weights[$i] = $w is out of bounds: '
        '(${_lowerBoundsWeights[i]}, ${_upperBoundsWeights[i]})',
      );
    }
    if (errors.isNotEmpty) {
      throw ArgumentError(
        'One or more weights are out of bounds:\n${errors.join('\n')}',
      );
    }
    if (!(desiredRetention > 0 && desiredRetention < 1)) {
      throw ArgumentError.value(
        desiredRetention,
        'desiredRetention',
        'must be between 0 and 1 (exclusive)',
      );
    }
    if (maximumInterval < 1) {
      throw ArgumentError.value(
        maximumInterval,
        'maximumInterval',
        'must be at least 1',
      );
    }
    if (dayStartHour < 0 || dayStartHour > 23) {
      throw ArgumentError.value(dayStartHour, 'dayStartHour', 'must be 0–23');
    }
  }

  FsrsParams copyWith({
    List<double>? weights,
    double? desiredRetention,
    List<Duration>? learningSteps,
    List<Duration>? relearningSteps,
    int? maximumInterval,
    int? dayStartHour,
    bool? enableFuzz,
  }) {
    return FsrsParams(
      weights: weights ?? this.weights,
      desiredRetention: desiredRetention ?? this.desiredRetention,
      learningSteps: learningSteps ?? this.learningSteps,
      relearningSteps: relearningSteps ?? this.relearningSteps,
      maximumInterval: maximumInterval ?? this.maximumInterval,
      dayStartHour: dayStartHour ?? this.dayStartHour,
      enableFuzz: enableFuzz ?? this.enableFuzz,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FsrsParams &&
      _listEquals(other.weights, weights) &&
      other.desiredRetention == desiredRetention &&
      _listEquals(other.learningSteps, learningSteps) &&
      _listEquals(other.relearningSteps, relearningSteps) &&
      other.maximumInterval == maximumInterval &&
      other.dayStartHour == dayStartHour &&
      other.enableFuzz == enableFuzz;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(weights),
        desiredRetention,
        Object.hashAll(learningSteps),
        Object.hashAll(relearningSteps),
        maximumInterval,
        dayStartHour,
        enableFuzz,
      );
}

/// Converts between instants and local wall-clock fields. The only part of
/// the scheduler that knows about time zones; it holds no day logic.
abstract class LocalTimeZone {
  const LocalTimeZone();

  /// Local wall-clock fields of [wallMs]. Only the year, month, day and hour
  /// of the returned value are used.
  DateTime toLocal(int wallMs);

  /// The instant (ms since epoch) of local time [year]-[month]-[day]
  /// [hour]:00.
  int fromLocal(int year, int month, int day, int hour);
}

/// The time zone of the device.
class SystemLocalTimeZone extends LocalTimeZone {
  const SystemLocalTimeZone();

  @override
  DateTime toLocal(int wallMs) => DateTime.fromMillisecondsSinceEpoch(wallMs);

  @override
  int fromLocal(int year, int month, int day, int hour) =>
      DateTime(year, month, day, hour).millisecondsSinceEpoch;
}

/// Derived scheduling state of one card. Never synced: it is recomputed by
/// replaying the card's review events.
class CardSchedule {
  const CardSchedule({
    required this.state,
    required this.step,
    required this.stability,
    required this.difficulty,
    required this.dueMs,
    required this.lastReviewMs,
    required this.reps,
    required this.lapses,
  });

  /// A card that was never reviewed. Due at epoch 0, i.e. due now.
  static const initial = CardSchedule(
    state: CardState.newCard,
    step: null,
    stability: null,
    difficulty: null,
    dueMs: 0,
    lastReviewMs: null,
    reps: 0,
    lapses: 0,
  );

  final CardState state;

  /// Current (re)learning step, null in review state.
  final int? step;
  final double? stability;
  final double? difficulty;
  final int dueMs;
  final int? lastReviewMs;
  final int reps;
  final int lapses;

  @override
  bool operator ==(Object other) =>
      other is CardSchedule &&
      other.state == state &&
      other.step == step &&
      other.stability == stability &&
      other.difficulty == difficulty &&
      other.dueMs == dueMs &&
      other.lastReviewMs == lastReviewMs &&
      other.reps == reps &&
      other.lapses == lapses;

  @override
  int get hashCode => Object.hash(
        state,
        step,
        stability,
        difficulty,
        dueMs,
        lastReviewMs,
        reps,
        lapses,
      );

  @override
  String toString() => 'CardSchedule(state: $state, step: $step, '
      'stability: $stability, difficulty: $difficulty, dueMs: $dueMs, '
      'lastReviewMs: $lastReviewMs, reps: $reps, lapses: $lapses)';
}

/// Where a review moves the card: a (re)learning step after [stepDelay], or
/// review state when [stepDelay] is null.
typedef _Next = ({CardState state, int? step, Duration? stepDelay});

const _Next _toReview = (state: CardState.review, step: null, stepDelay: null);

/// The FSRS-6 scheduler with study-day arithmetic.
class Fsrs {
  Fsrs({FsrsParams? params, this.tz = const SystemLocalTimeZone()})
      : params = params ?? FsrsParams() {
    _decay = -this.params.weights[20];
    _factor = math.pow(0.9, 1 / _decay) - 1;
  }

  final FsrsParams params;
  final LocalTimeZone tz;

  late final double _decay;
  late final double _factor;

  List<double> get _w => params.weights;

  /// Study day of [ms]: days since epoch of the local calendar date, where a
  /// local time before `dayStartHour` still belongs to the previous date.
  /// Calendar dates (not 24-hour periods) keep this right across DST changes.
  int dayOf(int ms) {
    final local = tz.toLocal(ms);
    final shift = local.hour < params.dayStartHour ? 1 : 0;
    final date = DateTime.utc(local.year, local.month, local.day - shift);
    return date.millisecondsSinceEpoch ~/ _msPerDay;
  }

  /// The instant study day [day] starts (local `dayStartHour`).
  int startOfDay(int day) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      day * _msPerDay,
      isUtc: true,
    );
    return tz.fromLocal(date.year, date.month, date.day, params.dayStartHour);
  }

  /// Predicted probability that [card] is recalled at [nowMs]; 0 for a card
  /// that was never reviewed.
  double retrievability(CardSchedule card, int nowMs) {
    final last = card.lastReviewMs;
    final stability = card.stability;
    if (last == null || stability == null) return 0;
    final elapsed = math.max(0, dayOf(nowMs) - dayOf(last));
    return _retrievability(stability, elapsed);
  }

  /// Applies one review with [rating] at wall-clock [tMs]. [fuzzSeed] seeds
  /// the interval fuzz; replay derives it from `(cardId, h)`.
  ///
  /// [tMs] earlier than the last review (clock skew between devices) is
  /// clamped to the last review, so elapsed time is never negative.
  CardSchedule review(
    CardSchedule card,
    Rating rating,
    int tMs, {
    int fuzzSeed = 0,
  }) {
    final last = card.lastReviewMs;
    final t = last == null ? tMs : math.max(tMs, last);
    final elapsedDays = last == null ? 0 : math.max(0, dayOf(t) - dayOf(last));

    final memo = _nextMemo(card, rating, elapsedDays);
    final next = _nextStep(card, rating);
    final lapses = card.lapses +
        (card.state == CardState.review && rating == Rating.again ? 1 : 0);

    final stepDelay = next.stepDelay;
    final dueMs = stepDelay == null
        ? startOfDay(dayOf(t) + _reviewInterval(memo.stability, fuzzSeed))
        : t + stepDelay.inMilliseconds;

    return CardSchedule(
      state: next.state,
      step: next.step,
      stability: memo.stability,
      difficulty: memo.difficulty,
      dueMs: dueMs,
      lastReviewMs: t,
      reps: card.reps + 1,
      lapses: lapses,
    );
  }

  ({double stability, double difficulty}) _nextMemo(
    CardSchedule card,
    Rating rating,
    int elapsedDays,
  ) {
    final stability = card.stability;
    final difficulty = card.difficulty;
    if (stability == null || difficulty == null) {
      return (
        stability: _initialStability(rating),
        difficulty: _initialDifficulty(rating),
      );
    }
    final nextDifficulty = _nextDifficulty(difficulty, rating);
    if (elapsedDays < 1) {
      return (
        stability: _shortTermStability(stability, rating),
        difficulty: nextDifficulty,
      );
    }
    final r = _retrievability(stability, elapsedDays);
    return (
      stability: _nextStability(difficulty, stability, r, rating),
      difficulty: nextDifficulty,
    );
  }

  _Next _nextStep(CardSchedule card, Rating rating) {
    final step = card.step ?? 0;
    switch (card.state) {
      case CardState.newCard:
      case CardState.learning:
        return _throughSteps(
          CardState.learning,
          params.learningSteps,
          step,
          rating,
        );
      case CardState.relearning:
        return _throughSteps(
          CardState.relearning,
          params.relearningSteps,
          step,
          rating,
        );
      case CardState.review:
        if (rating != Rating.again || params.relearningSteps.isEmpty) {
          return _toReview;
        }
        return (
          state: CardState.relearning,
          step: 0,
          stepDelay: params.relearningSteps[0],
        );
    }
  }

  _Next _throughSteps(
    CardState state,
    List<Duration> steps,
    int step,
    Rating rating,
  ) {
    // The second check covers a card scheduled with more steps than the
    // current params have.
    if (steps.isEmpty) return _toReview;
    if (step >= steps.length && rating != Rating.again) return _toReview;
    switch (rating) {
      case Rating.again:
        return (state: state, step: 0, stepDelay: steps[0]);
      case Rating.hard:
        if (step == 0 && steps.length == 1) {
          return (state: state, step: 0, stepDelay: steps[0] * 1.5);
        }
        if (step == 0) {
          return (state: state, step: 0, stepDelay: (steps[0] + steps[1]) ~/ 2);
        }
        return (state: state, step: step, stepDelay: steps[step]);
      case Rating.good:
        if (step + 1 >= steps.length) return _toReview;
        return (state: state, step: step + 1, stepDelay: steps[step + 1]);
      case Rating.easy:
        return _toReview;
    }
  }

  int _reviewInterval(double stability, int fuzzSeed) {
    final days = _nextInterval(stability);
    if (!params.enableFuzz) return days;
    return _fuzzedInterval(days, SeededRandom(fuzzSeed).nextDouble());
  }

  double _retrievability(double stability, int elapsedDays) =>
      math.pow(1 + _factor * elapsedDays / stability, _decay).toDouble();

  double _clampDifficulty(double d) => d.clamp(_minDifficulty, _maxDifficulty);

  double _clampStability(double s) => math.max(s, fsrsStabilityMin);

  double _initialStability(Rating rating) =>
      _clampStability(_w[rating.value - 1]);

  double _initialDifficulty(Rating rating) => _clampDifficulty(
        _w[4] - math.exp(_w[5] * (rating.value - 1)) + 1,
      );

  int _nextInterval(double stability) {
    final raw = stability /
        _factor *
        (math.pow(params.desiredRetention, 1 / _decay) - 1);
    return raw.round().clamp(1, params.maximumInterval);
  }

  double _shortTermStability(double stability, Rating rating) {
    var increase = math.exp(_w[17] * (rating.value - 3 + _w[18])) *
        math.pow(stability, -_w[19]);
    if (rating == Rating.good || rating == Rating.easy) {
      increase = math.max(increase, 1.0);
    }
    return _clampStability(stability * increase);
  }

  double _nextDifficulty(double difficulty, Rating rating) {
    final delta = -(_w[6] * (rating.value - 3));
    // Linear damping, then mean reversion toward the initial Easy difficulty.
    final damped = difficulty + (10.0 - difficulty) * delta / 9.0;
    final reverted =
        _w[7] * _initialDifficulty(Rating.easy) + (1 - _w[7]) * damped;
    return _clampDifficulty(reverted);
  }

  double _nextStability(
    double difficulty,
    double stability,
    double retrievability,
    Rating rating,
  ) {
    if (rating == Rating.again) {
      return _clampStability(
        _nextForgetStability(difficulty, stability, retrievability),
      );
    }
    return _clampStability(
      _nextRecallStability(difficulty, stability, retrievability, rating),
    );
  }

  double _nextForgetStability(
    double difficulty,
    double stability,
    double retrievability,
  ) {
    final longTerm = _w[11] *
        math.pow(difficulty, -_w[12]) *
        (math.pow(stability + 1, _w[13]) - 1) *
        math.exp((1 - retrievability) * _w[14]);
    final shortTerm = stability / math.exp(_w[17] * _w[18]);
    return math.min(longTerm, shortTerm);
  }

  double _nextRecallStability(
    double difficulty,
    double stability,
    double retrievability,
    Rating rating,
  ) {
    final hardPenalty = rating == Rating.hard ? _w[15] : 1.0;
    final easyBonus = rating == Rating.easy ? _w[16] : 1.0;
    return stability *
        (1 +
            math.exp(_w[8]) *
                (11 - difficulty) *
                math.pow(stability, -_w[9]) *
                (math.exp((1 - retrievability) * _w[10]) - 1) *
                hardPenalty *
                easyBonus);
  }

  /// Moves [days] to a value in its upstream fuzz range, picked by [u] in
  /// `[0, 1)`. Intervals under 2.5 days are never fuzzed.
  ///
  /// Upstream rounds `min + u * (max - min + 1)`, which can land on max + 1;
  /// flooring picks every day of `[min, max]` with the same probability.
  int _fuzzedInterval(int days, double u) {
    if (days < 2.5) return days;
    final bounds = fuzzBounds(days);
    final fuzzed = (bounds.min + u * (bounds.max - bounds.min + 1)).floor();
    return math.min(fuzzed, params.maximumInterval);
  }

  /// The range a fuzzed interval of [days] days may land in. Exposed for
  /// tests.
  ({int min, int max}) fuzzBounds(int days) {
    var delta = 1.0;
    for (final range in _fuzzRanges) {
      delta += range.factor *
          math.max(math.min(days.toDouble(), range.end) - range.start, 0.0);
    }
    final hi = math.min((days + delta).round(), params.maximumInterval);
    final lo = math.min(math.max(2, (days - delta).round()), hi);
    return (min: lo, max: hi);
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
