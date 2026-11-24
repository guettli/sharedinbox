import 'dart:convert';

import 'package:sharedinbox/core/flashcards/fsrs.dart';

/// The scheduler params of the review log (ENCRYPTED-OBJECTS.md §7, #1380):
/// two kinds of device-state keys (5.4 item 4), effective account-global.
///
/// - [fsrsParamsKey]: `{weights, desiredRetention, maximumInterval,
///   enableFuzz}` for every deck.
/// - [deckOptionsKey]: `{learningSteps, relearningSteps, dayStartHour,
///   newPerDay, desiredRetention?}` of one deck; steps in seconds. Its
///   `desiredRetention` overrides the global one; `newPerDay` caps the new
///   cards studied per study day (#1381).
///
/// A missing or invalid field falls back to its default ([FsrsParams]).

/// The device-state key of the global FSRS params.
const fsrsParamsKey = 'fsrs.params';

/// The device-state key of the options of deck [deckId].
String deckOptionsKey(String deckId) => 'deck.$deckId.options';

/// The options of one deck.
class DeckOptions {
  const DeckOptions({
    this.learningSteps = const [Duration(minutes: 1), Duration(minutes: 10)],
    this.relearningSteps = const [Duration(minutes: 10)],
    this.dayStartHour = 4,
    this.newPerDay = defaultNewPerDay,
    this.desiredRetention,
  });

  /// The options of deck [deckId] in the effective device state [state];
  /// a missing or invalid field falls back to its default.
  factory DeckOptions.of(Map<String, Object?> state, String deckId) {
    final json = state[deckOptionsKey(deckId)];
    if (json is! Map) return const DeckOptions();
    final hour = json['dayStartHour'];
    final perDay = json['newPerDay'];
    const defaults = DeckOptions();
    return DeckOptions(
      learningSteps: _steps(json['learningSteps']) ?? defaults.learningSteps,
      relearningSteps:
          _steps(json['relearningSteps']) ?? defaults.relearningSteps,
      dayStartHour:
          hour is int && hour >= 0 && hour < 24 ? hour : defaults.dayStartHour,
      newPerDay: perDay is int && perDay >= 0 ? perDay : defaultNewPerDay,
      desiredRetention: switch (json['desiredRetention']) {
        final num r => r.toDouble(),
        _ => null,
      },
    );
  }

  /// New cards per study day unless a deck says otherwise.
  static const defaultNewPerDay = 20;

  final List<Duration> learningSteps;
  final List<Duration> relearningSteps;

  /// Local hour (0–23) at which a study day starts.
  final int dayStartHour;

  /// At most this many new cards are studied per study day (a new card
  /// counts on its first rating).
  final int newPerDay;

  /// Overrides the global `desiredRetention` when set.
  final double? desiredRetention;

  Map<String, Object?> toJson() => {
        'learningSteps': [for (final s in learningSteps) s.inSeconds],
        'relearningSteps': [for (final s in relearningSteps) s.inSeconds],
        'dayStartHour': dayStartHour,
        'newPerDay': newPerDay,
        if (desiredRetention != null) 'desiredRetention': desiredRetention,
      };
}

/// The value of [fsrsParamsKey] for [params].
Map<String, Object?> fsrsParamsJson(FsrsParams params) => {
      'weights': params.weights,
      'desiredRetention': params.desiredRetention,
      'maximumInterval': params.maximumInterval,
      'enableFuzz': params.enableFuzz,
    };

/// The effective params of deck [deckId] (null: a card whose deck is not
/// known here yet) from the effective device state [state].
FsrsParams effectiveFsrsParams(Map<String, Object?> state, String? deckId) {
  var params = FsrsParams();
  final global = state[fsrsParamsKey];
  if (global is Map) {
    final weights = _doubles(global['weights']);
    if (weights != null) {
      params = _tryCopy(params, (p) => p.copyWith(weights: weights));
    }
    params = _withRetention(params, global['desiredRetention']);
    if (global['maximumInterval'] case final int max) {
      params = _tryCopy(params, (p) => p.copyWith(maximumInterval: max));
    }
    if (global['enableFuzz'] case final bool fuzz) {
      params = params.copyWith(enableFuzz: fuzz);
    }
  }
  final deck = deckId == null ? null : state[deckOptionsKey(deckId)];
  if (deck is! Map) return params;
  final learning = _steps(deck['learningSteps']);
  if (learning != null) params = params.copyWith(learningSteps: learning);
  final relearning = _steps(deck['relearningSteps']);
  if (relearning != null) params = params.copyWith(relearningSteps: relearning);
  if (deck['dayStartHour'] case final int hour) {
    params = _tryCopy(params, (p) => p.copyWith(dayStartHour: hour));
  }
  return _withRetention(params, deck['desiredRetention']);
}

/// A stable string of everything [params] holds: a schedule computed with
/// other params is stale.
String paramsKeyOf(FsrsParams params) => jsonEncode([
      params.weights,
      params.desiredRetention,
      [for (final s in params.learningSteps) s.inMilliseconds],
      [for (final s in params.relearningSteps) s.inMilliseconds],
      params.maximumInterval,
      params.dayStartHour,
      params.enableFuzz,
    ]);

FsrsParams _withRetention(FsrsParams params, Object? value) {
  if (value is! num) return params;
  return _tryCopy(
    params,
    (p) => p.copyWith(desiredRetention: value.toDouble()),
  );
}

/// [copy] of [params], or [params] when a value is out of bounds.
FsrsParams _tryCopy(FsrsParams params, FsrsParams Function(FsrsParams) copy) {
  try {
    return copy(params);
    // FsrsParams validates in its constructor and throws ArgumentError.
    // ignore: avoid_catching_errors
  } on ArgumentError {
    return params;
  }
}

List<double>? _doubles(Object? json) {
  if (json is! List || json.any((v) => v is! num)) return null;
  return [for (final v in json) (v as num).toDouble()];
}

/// Steps in seconds; null unless a list of positive numbers.
List<Duration>? _steps(Object? json) {
  if (json is! List || json.any((v) => v is! num || v <= 0)) return null;
  return [
    for (final v in json) Duration(milliseconds: ((v as num) * 1000).round()),
  ];
}
