import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';

final _h = Hlc(1700000000000, 2, 'devA');

LogEvent _wire(Map<String, Object?> json) =>
    LogEvent(seq: 7, hlc: _h, json: json);

void main() {
  test('a review round-trips through the wire event', () {
    final review = ReviewEvent(
      deviceId: 'devA',
      seq: 7,
      h: _h.encode(),
      cardId: 'c1',
      t: 1700000000123,
      rating: 3,
      ms: 4500,
    );
    expect(review.toJson(), {
      'op': 'review',
      'c': 'c1',
      's': 7,
      'h': _h.encode(),
      't': 1700000000123,
      'r': 3,
      'ms': 4500,
    });
    expect(CardEvent.fromLogEvent(_wire(review.toJson())), review);
  });

  test('an undo round-trips through the wire event', () {
    final undo = UndoEvent(
      deviceId: 'devA',
      seq: 7,
      h: _h.encode(),
      refDeviceId: 'devB',
      refSeq: 3,
    );
    expect(undo.toJson(), {
      'op': 'undo',
      's': 7,
      'h': _h.encode(),
      'ref': ['devB', 3],
    });
    expect(CardEvent.fromLogEvent(_wire(undo.toJson())), undo);
  });

  test('the deviceId comes from the HLC (the segment head), not the event', () {
    final event = CardEvent.fromLogEvent(
      _wire({'op': 'review', 'c': 'c1', 't': 1, 'r': 1, 'device': 'other'}),
    )!;
    expect(event.deviceId, 'devA');
    expect((event as ReviewEvent).ms, 0);
  });

  test('unknown ops and malformed events are skipped', () {
    for (final json in [
      {'op': 'flag', 'c': 'c1'},
      <String, Object?>{},
      {'op': 'review', 'c': 1, 't': 1, 'r': 3},
      {'op': 'review', 'c': 'c1', 'r': 3},
      {'op': 'review', 'c': 'c1', 't': 1, 'r': '3'},
      {'op': 'undo'},
      {
        'op': 'undo',
        'ref': ['devB'],
      },
      {
        'op': 'undo',
        'ref': [1, 2],
      },
      {
        'op': 'undo',
        'ref': ['devB', '2'],
      },
    ]) {
      expect(CardEvent.fromLogEvent(_wire(json)), isNull, reason: '$json');
    }
  });
}
