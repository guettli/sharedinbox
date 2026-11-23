import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';

void main() {
  test('without device state every deck has the defaults', () {
    expect(effectiveFsrsParams(const {}, 'deck-1'), FsrsParams());
    expect(effectiveFsrsParams(const {}, null), FsrsParams());
  });

  test('the global params and the deck options round-trip', () {
    final weights = [...defaultFsrsWeights]..[0] = 0.5;
    final global = FsrsParams(
      weights: weights,
      desiredRetention: 0.85,
      maximumInterval: 365,
      enableFuzz: false,
    );
    const options = DeckOptions(
      learningSteps: [Duration(minutes: 5)],
      relearningSteps: [Duration(minutes: 2), Duration(hours: 1)],
      dayStartHour: 6,
    );
    final state = {
      fsrsParamsKey: fsrsParamsJson(global),
      deckOptionsKey('deck-1'): options.toJson(),
    };

    expect(effectiveFsrsParams(state, 'deck-2'), global);
    expect(
      effectiveFsrsParams(state, 'deck-1'),
      global.copyWith(
        learningSteps: options.learningSteps,
        relearningSteps: options.relearningSteps,
        dayStartHour: 6,
      ),
    );
    // A card whose deck is not known here: the global params only.
    expect(effectiveFsrsParams(state, null), global);
  });

  test("a deck's desiredRetention overrides the global one", () {
    final state = {
      fsrsParamsKey: {'desiredRetention': 0.8},
      deckOptionsKey('deck-1'):
          const DeckOptions(desiredRetention: 0.95).toJson(),
    };
    expect(effectiveFsrsParams(state, 'deck-1').desiredRetention, 0.95);
    expect(effectiveFsrsParams(state, 'deck-2').desiredRetention, 0.8);
    expect(const DeckOptions().toJson(), isNot(contains('desiredRetention')));
  });

  test('invalid or missing fields fall back to the defaults, field by field',
      () {
    final state = {
      fsrsParamsKey: {
        'weights': [1, 2, 3],
        'desiredRetention': 1.5,
        'maximumInterval': 0,
        'enableFuzz': 'yes',
      },
      deckOptionsKey('deck-1'): {
        'learningSteps': [60, -1],
        'relearningSteps': 'often',
        'dayStartHour': 30,
        'desiredRetention': 0.7,
      },
    };
    expect(
      effectiveFsrsParams(state, 'deck-1'),
      FsrsParams(desiredRetention: 0.7),
    );
    expect(
      effectiveFsrsParams({fsrsParamsKey: 'not a map'}, 'deck-1'),
      FsrsParams(),
    );
    expect(
      effectiveFsrsParams(
        {
          fsrsParamsKey: {
            'weights': [for (var i = 0; i < 21; i++) 'w'],
          },
        },
        null,
      ),
      FsrsParams(),
    );
    // Out of bounds weights.
    expect(
      effectiveFsrsParams(
        {
          fsrsParamsKey: {
            'weights': [for (var i = 0; i < 21; i++) 1000],
          },
        },
        null,
      ),
      FsrsParams(),
    );
  });

  test('steps are in seconds and may be fractional', () {
    final params = effectiveFsrsParams(
      {
        deckOptionsKey('d'): {
          'learningSteps': [30, 1.5],
        },
      },
      'd',
    );
    expect(params.learningSteps, [
      const Duration(seconds: 30),
      const Duration(milliseconds: 1500),
    ]);
  });

  test('the params key changes with every field', () {
    final base = FsrsParams();
    final keys = {
      paramsKeyOf(base),
      paramsKeyOf(base.copyWith(desiredRetention: 0.8)),
      paramsKeyOf(base.copyWith(maximumInterval: 10)),
      paramsKeyOf(base.copyWith(dayStartHour: 0)),
      paramsKeyOf(base.copyWith(enableFuzz: false)),
      paramsKeyOf(base.copyWith(learningSteps: const [Duration(minutes: 2)])),
      paramsKeyOf(
        base.copyWith(relearningSteps: const [Duration(minutes: 2)]),
      ),
      paramsKeyOf(
        base.copyWith(weights: [...defaultFsrsWeights]..[0] = 0.5),
      ),
    };
    expect(keys, hasLength(8));
    expect(paramsKeyOf(FsrsParams()), paramsKeyOf(base));
  });
}
