import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

LogEvent _event(int seq, int wallMs, [String device = 'devA']) => LogEvent(
      seq: seq,
      hlc: hlcAt(wallMs, device),
      json: {'n': seq, 'extra': 'kept'},
    );

SegmentHead _head(List<LogRange> covers) => SegmentHead(
      device: 'devA',
      seqFrom: 1,
      seqTo: 1,
      covers: covers,
      period: '2026-11',
      hlcMax: hlcAt(1),
    );

void main() {
  test('kinds and their log', () {
    expect(segKind('review'), 'review-seg');
    expect(packKind('review'), 'review-pack');
    expect(logOfKind('review-seg'), 'review');
    expect(logOfKind('undo-pack'), 'undo');
    expect(logOfKind('entry'), isNull);
    expect(logOfKind('-seg'), isNull);
    expect(logOfKind(null), isNull);
    expect(isPackKind('review-pack'), isTrue);
    expect(isPackKind('review-seg'), isFalse);
  });

  test('the body round-trips and keeps unknown fields', () {
    final events = [_event(1, 10), _event(2, 11)];
    final decoded = decodeEventsBody(encodeEventsBody(events));
    expect([for (final e in decoded) e.seq], [1, 2]);
    expect(decoded.first.json['extra'], 'kept');
    expect(decoded.first.deviceId, 'devA');
    expect(
      () => decodeEventsBody(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => LogEvent.fromJson({'s': 0, 'h': hlcAt(1).encode()}),
      throwsFormatException,
    );
  });

  test('dedupe by (deviceId, seq), ordered by (h, deviceId, seq)', () {
    final events = dedupeEvents([
      _event(2, 20),
      _event(1, 10),
      _event(1, 10),
      _event(1, 15, 'devB'),
    ]);
    expect(
      [for (final e in events) '${e.deviceId}/${e.seq}'],
      ['devA/1', 'devB/1', 'devA/2'],
    );
  });

  test('ranges merge where they touch; covering is per device', () {
    expect(
      mergeRanges(const [
        LogRange('a', 4, 6),
        LogRange('a', 1, 3),
        LogRange('a', 9, 9),
        LogRange('b', 1, 2),
      ]),
      const [LogRange('a', 1, 6), LogRange('a', 9, 9), LogRange('b', 1, 2)],
    );
    final pack = _head(const [LogRange('a', 1, 6), LogRange('b', 1, 2)]);
    expect(isCovered(_head(const [LogRange('a', 2, 3)]), [pack]), isTrue);
    expect(
      isCovered(_head(const [LogRange('a', 2, 3), LogRange('b', 3, 3)]), [
        pack,
      ]),
      isFalse,
    );
    expect(isCovered(_head(const [LogRange('c', 1, 1)]), [pack]), isFalse);
    expect(isCovered(pack, const []), isFalse);
  });

  test('the period is the UTC month of the HLC', () {
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    expect(periodOf(hlcAt(ms(DateTime.utc(2026, 11, 30, 23)))), '2026-11');
    expect(periodOf(hlcAt(ms(DateTime.utc(2027)))), '2027-01');
  });

  test('a segment object round-trips through its head and parts', () {
    final events = [_event(1, 10), _event(2, 11)];
    final head = SegmentHead.of('devA', events, period: '2026-11');
    expect(head.seqFrom, 1);
    expect(head.seqTo, 2);
    expect(head.covers, const [LogRange('devA', 1, 2)]);
    expect(head.hlcMax, hlcAt(11));
    final object = segmentObject(
      log: 'review',
      itemId: 'i',
      collectionId: 'deck-1',
      versionId: Hlc(12, 0, 'devA'),
      head: head,
      events: events,
      pack: true,
    );
    expect(object.head.kind, 'review-pack');
    final read = readSegment(object)!;
    expect(read.head.covers, head.covers);
    expect([for (final e in read.events) e.seq], [1, 2]);
    expect(readSegment(testObject()), isNull);
    expect(
      readSegment(
        InnerObject(
          head: ObjectHead(
            itemId: 'i',
            collectionId: 'deck-1',
            versionId: hlcAt(1),
            kind: 'review-seg',
            extra: const {'device': 'x'},
          ),
        ),
      ),
      isNull,
    );
  });
}
