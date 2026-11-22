import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/card_replay.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/seeded_random.dart';

import 'fake_time_zones.dart';

const _tz = FixedOffsetTimeZone(Duration(hours: 2));
const _day = Duration.millisecondsPerDay;
final _t0 = DateTime.utc(2026, 5, 10, 10).millisecondsSinceEpoch;

ReviewEvent _review(
  String device,
  int seq,
  String h,
  int t,
  int rating, {
  String card = 'c1',
}) =>
    ReviewEvent(
      deviceId: device,
      seq: seq,
      h: h,
      cardId: card,
      t: t,
      rating: rating,
      ms: 1200,
    );

UndoEvent _undo(String device, int seq, String h, String refDevice, int ref) =>
    UndoEvent(
      deviceId: device,
      seq: seq,
      h: h,
      refDeviceId: refDevice,
      refSeq: ref,
    );

/// A realistic log: learning steps, then reviews days apart, one lapse.
final _log = <CardEvent>[
  _review('A', 1, '0001', _t0, 3),
  _review('A', 2, '0002', _t0 + 600000, 3),
  _review('B', 1, '0003', _t0 + 3 * _day, 3),
  _review('A', 3, '0004', _t0 + 15 * _day, 3),
  _review('B', 2, '0005', _t0 + 60 * _day, 1),
  _review('B', 3, '0006', _t0 + 60 * _day + 600000, 3),
  _review('A', 4, '0007', _t0 + 63 * _day, 4),
];

CardSchedule _replay(Iterable<CardEvent> events, {FsrsParams? params}) =>
    replayCard('c1', events, params: params, tz: _tz);

void main() {
  test('replay equals folding the sorted reviews through Fsrs.review', () {
    final fsrs = Fsrs(tz: _tz);
    var expected = CardSchedule.initial;
    for (final e in _log.cast<ReviewEvent>()) {
      expected = fsrs.review(
        expected,
        Rating.fromValue(e.rating)!,
        e.t,
        fuzzSeed: fnv1a32('c1\u0000${e.h}'),
      );
    }
    final actual = _replay(_log);
    expect(actual, expected);
    expect(actual.reps, 7);
    expect(actual.lapses, 1);
    expect(actual.state, CardState.review);
  });

  test('no events give the initial schedule', () {
    expect(_replay(const []), CardSchedule.initial);
  });

  test('input order does not matter (fuzz on)', () {
    final expected = _replay(_log);
    for (var i = 0; i < 50; i++) {
      final shuffled = List.of(_log)..shuffle(Random(i));
      expect(_replay(shuffled), expected, reason: 'shuffle seed $i');
    }
  });

  test('duplicate events count once', () {
    expect(_replay([..._log, ..._log, _log.first]), _replay(_log));
  });

  test('conflicting events with one id resolve the same in any order', () {
    final a = _review('A', 9, '0008', _t0 + 70 * _day, 3);
    final b = _review('A', 9, '0009', _t0 + 71 * _day, 1);
    final ab = _replay([..._log, a, b]);
    expect(_replay([b, ..._log, a]), ab);
    expect(ab.reps, _log.length + 1);
  });

  test('reviews from two devices with interleaved h both count', () {
    final events = [
      _review('A', 1, '0001', _t0, 4),
      _review('B', 1, '0002', _t0 + 5 * _day, 3),
      _review('A', 2, '0003', _t0 + 5 * _day + 1000, 3),
      _review('B', 2, '0004', _t0 + 20 * _day, 3),
    ];
    final s = _replay(events);
    expect(s.reps, 4);
    expect(_replay(events.reversed), s);
  });

  test('ties on h are broken by deviceId, then seq', () {
    final events = [
      _review('B', 1, '0001', _t0, 1),
      _review('A', 2, '0001', _t0, 4),
      _review('A', 1, '0001', _t0, 3),
    ];
    final fsrs = Fsrs(tz: _tz);
    var expected = CardSchedule.initial;
    for (final r in [Rating.good, Rating.easy, Rating.again]) {
      expected = fsrs.review(
        expected,
        r,
        _t0,
        fuzzSeed: fnv1a32('c1\u00000001'),
      );
    }
    expect(_replay(events), expected);
  });

  test('other cards and invalid ratings are ignored', () {
    final noise = [
      _review('A', 20, '0003', _t0 + 3 * _day, 1, card: 'c2'),
      _review('A', 21, '0004', _t0 + 4 * _day, 0),
      _review('A', 22, '0005', _t0 + 4 * _day, 5),
    ];
    expect(_replay([..._log, ...noise]), _replay(_log));
  });

  group('undo', () {
    test('an undone review is ignored', () {
      final withUndo = [..._log, _undo('B', 10, '0008', 'A', 4)];
      final without = _log.where(
        (e) => !(e.deviceId == 'A' && e.seq == 4),
      );
      expect(_replay(withUndo), _replay(without));
      expect(_replay(withUndo).reps, _log.length - 1);
    });

    test('an undo of a missing review does nothing', () {
      expect(
        _replay([..._log, _undo('A', 10, '0008', 'C', 1)]),
        _replay(_log),
      );
    });

    test('an undo may come before its target in the input', () {
      final undo = _undo('A', 10, '0008', 'B', 2);
      expect(
        _replay([undo, ..._log]),
        _replay(_log.where((e) => !(e.deviceId == 'B' && e.seq == 2))),
      );
    });
  });

  test('clock skew: a later h with an earlier t counts as elapsed 0', () {
    final events = [
      _review('A', 1, '0001', _t0, 4),
      _review('B', 1, '0002', _t0 - 3 * _day, 3),
    ];
    final s = _replay(events);
    expect(s.reps, 2);
    expect(s.lastReviewMs, _t0);
    expect(s.stability!.isFinite, isTrue);
    expect(s.difficulty!.isFinite, isTrue);
    expect(s.dueMs, greaterThan(_t0));

    // Same as a second review at the same instant.
    expect(
      s,
      _replay([
        _review('A', 1, '0001', _t0, 4),
        _review('B', 1, '0002', _t0, 3),
      ]),
    );
  });

  group('fuzz', () {
    test('the same (cardId, h) gives the same due date', () {
      final a = replayCard('c1', _log, tz: _tz);
      final b = replayCard('c1', List.of(_log.reversed), tz: _tz);
      expect(a.dueMs, b.dueMs);
    });

    test('different h values give different due dates', () {
      final dues = <int>{};
      for (var i = 0; i < 20; i++) {
        final events = [
          _review('A', 1, 'h$i-1', _t0, 4),
          _review('A', 2, 'h$i-2', _t0 + 20 * _day, 3),
        ];
        dues.add(_replay(events).dueMs);
      }
      expect(dues.length, greaterThanOrEqualTo(2));
    });

    test('the cardId is part of the seed', () {
      final dues = <int>{};
      for (var i = 0; i < 20; i++) {
        final events = [
          _review('A', 1, '0001', _t0, 4, card: 'card-$i'),
          _review('A', 2, '0002', _t0 + 20 * _day, 3, card: 'card-$i'),
        ];
        dues.add(replayCard('card-$i', events, tz: _tz).dueMs);
      }
      expect(dues.length, greaterThanOrEqualTo(2));
    });
  });

  test('params are injectable; a change is just another replay', () {
    final base = _replay(_log, params: FsrsParams(enableFuzz: false));
    final lowRetention = _replay(
      _log,
      params: FsrsParams(enableFuzz: false, desiredRetention: 0.8),
    );
    expect(lowRetention.dueMs, greaterThan(base.dueMs));
    expect(lowRetention.stability, base.stability);
  });

  test('defaults to the system time zone', () {
    final s = replayCard('c1', _log);
    expect(s.reps, _log.length);
    final due = DateTime.fromMillisecondsSinceEpoch(s.dueMs);
    expect((due.hour, due.minute), (4, 0));
  });

  group('events', () {
    test('equality, hashCode and toString', () {
      final r = _review('A', 1, '0001', _t0, 3);
      expect(r, _review('A', 1, '0001', _t0, 3));
      expect(r.hashCode, _review('A', 1, '0001', _t0, 3).hashCode);
      expect(r, isNot(_review('A', 1, '0001', _t0, 4)));
      expect(r.toString(), contains('rating: 3'));

      final u = _undo('A', 2, '0002', 'B', 1);
      expect(u, _undo('A', 2, '0002', 'B', 1));
      expect(u.hashCode, _undo('A', 2, '0002', 'B', 1).hashCode);
      expect(u, isNot(_undo('A', 2, '0002', 'B', 2)));
      expect(u.toString(), contains('refSeq: 1'));
    });
  });
}
