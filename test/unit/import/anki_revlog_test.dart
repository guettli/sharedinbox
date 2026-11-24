import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/import/anki_revlog.dart';

const _dev = 'import:dev';

AnkiRevlogRow _row(
  int id, {
  String? card = 'c1',
  int ease = 3,
  int type = 1,
  int ivl = 1,
  int time = 1000,
}) =>
    AnkiRevlogRow(
      id: id,
      cardId: card,
      ease: ease,
      time: time,
      type: type,
      ivl: ivl,
    );

void main() {
  test('learn, review, relearn and filtered rows rated 1-4 are events', () {
    final r = ankiReviewEvents(_dev, [
      _row(1000, type: 0, ease: 1),
      _row(1001, type: 1, ease: 2),
      _row(1002, type: 2, ease: 3),
      _row(1003, type: 3, ease: 4),
    ]);
    expect(r.skipped, 0);
    expect(r.events.map((e) => (e.rating, e.seq)), [
      (1, 1000),
      (2, 1001),
      (3, 1002),
      (4, 1003),
    ]);
  });

  test('maps id to seq, t and h; time to ms', () {
    final e =
        ankiReviewEvents(_dev, [_row(1735689600000, time: 4200)]).events.single;
    expect(e.deviceId, _dev);
    expect(e.seq, 1735689600000);
    expect(e.t, 1735689600000);
    expect(e.h, Hlc(1735689600000, 0, _dev).encode());
    expect(Hlc.parse(e.h).deviceId, _dev);
    expect(e.cardId, 'c1');
    expect(e.rating, 3);
    expect(e.ms, 4200);
  });

  test('manual, rescheduled, unrated and unknown-card rows are skipped', () {
    final r = ankiReviewEvents(_dev, [
      _row(1, type: 4, ease: 0, ivl: 5),
      _row(2, type: 5, ease: 0, ivl: 10),
      _row(3, ease: 0),
      _row(4, ease: 5),
      _row(5, card: null),
      _row(6),
    ]);
    expect(r.events.map((e) => e.seq), [6]);
    expect(r.skipped, 5);
  });

  test('rows up to and including the last reset of a card are dropped', () {
    final r = ankiReviewEvents(_dev, [
      _row(10),
      _row(20, type: 4, ease: 0, ivl: 0),
      _row(30),
      _row(40, type: 4, ease: 0, ivl: 0),
      _row(50),
      // Another card: the reset of c1 does not touch it.
      _row(15, card: 'c2'),
    ]);
    expect(r.events.map((e) => (e.cardId, e.seq)), [('c2', 15), ('c1', 50)]);
    expect(r.skipped, 4);
  });

  test('the events are in seq order whatever the input order', () {
    final r = ankiReviewEvents(_dev, [_row(30), _row(10), _row(20)]);
    expect(r.events.map((e) => e.seq), [10, 20, 30]);
  });

  test('the head of 1 000 non-consecutive events stays far below 256 KiB', () {
    const deviceId = 'import:AAAAAAAAAAAAAAAAAAAAAA';
    final events = ankiReviewEvents(deviceId, [
      for (var i = 0; i < 1000; i++) _row(1735689600000 + i * 86400000),
    ]).events;
    final head = SegmentHead.of(
      deviceId,
      [
        for (final e in events)
          LogEvent(seq: e.seq, hlc: Hlc.parse(e.h), json: e.toJson()),
      ],
      period: '2026-11',
    );
    expect(head.covers, hasLength(1000));
    expect(utf8.encode(jsonEncode(head.toExtra())).length, lessThan(64 * 1024));
  });
}
