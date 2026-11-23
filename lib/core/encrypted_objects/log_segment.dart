import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Log segments and packs (`ENCRYPTED-OBJECTS.md` 5.4 item 2, #1372): an
/// immutable batch of events, each identified by `(deviceId, seq)`. A pack
/// replaces the segments (and older packs) it [SegmentHead.covers]; readers
/// skip covered ones and always dedupe events.

/// The kind of a segment of [log], e.g. `review-seg`.
String segKind(String log) => '$log-seg';

/// The kind of a pack of [log], e.g. `review-pack`.
String packKind(String log) => '$log-pack';

/// The log a segment or pack [kind] belongs to, or null for another kind.
String? logOfKind(String? kind) {
  if (kind == null) return null;
  for (final suffix in const ['-seg', '-pack']) {
    if (kind.endsWith(suffix) && kind.length > suffix.length) {
      return kind.substring(0, kind.length - suffix.length);
    }
  }
  return null;
}

/// Whether [kind] is a pack (not a segment).
bool isPackKind(String? kind) => kind != null && kind.endsWith('-pack');

/// Content type of the gzip JSONL body part.
const logBodyContentType = 'application/jsonl+gzip';

/// One event: `s` is its `seq`, `h` its HLC (whose deviceId is the writer).
/// Every other field is opaque here and kept as is (5.2).
class LogEvent {
  LogEvent({required this.seq, required this.hlc, Map<String, Object?>? json})
      : json = Map.unmodifiable({...?json, 's': seq, 'h': hlc.encode()});

  /// Reads an event; throws [FormatException] without a valid `s` and `h`.
  factory LogEvent.fromJson(Map<String, Object?> json) {
    final seq = json['s'];
    if (seq is! int || seq < 1) throw const FormatException('bad event seq');
    return LogEvent(
      seq: seq,
      hlc: Hlc.parse(readStringField(json, 'h')),
      json: json,
    );
  }

  final int seq;
  final Hlc hlc;

  /// The whole event, `s` and `h` included.
  final Map<String, Object?> json;

  String get deviceId => hlc.deviceId;
}

/// `seqFrom..seqTo` (both included) of the events of [deviceId].
class LogRange {
  const LogRange(this.deviceId, this.seqFrom, this.seqTo);

  /// Reads `[deviceId, seqFrom, seqTo]`.
  factory LogRange.fromJson(Object? json) {
    if (json is! List ||
        json.length != 3 ||
        json[0] is! String ||
        json[1] is! int ||
        json[2] is! int) {
      throw const FormatException('bad covers range');
    }
    return LogRange(json[0] as String, json[1] as int, json[2] as int);
  }

  final String deviceId;
  final int seqFrom;
  final int seqTo;

  bool contains(LogRange other) =>
      other.deviceId == deviceId &&
      other.seqFrom >= seqFrom &&
      other.seqTo <= seqTo;

  List<Object> toJson() => [deviceId, seqFrom, seqTo];

  @override
  bool operator ==(Object other) =>
      other is LogRange &&
      other.deviceId == deviceId &&
      other.seqFrom == seqFrom &&
      other.seqTo == seqTo;

  @override
  int get hashCode => Object.hash(deviceId, seqFrom, seqTo);

  @override
  String toString() => '[$deviceId, $seqFrom, $seqTo]';
}

/// The kind fields of a segment or pack head: `{device, seqFrom, seqTo,
/// covers, period, hlcMax}`. A segment covers its own range; a pack the
/// ranges of everything it replaces.
class SegmentHead {
  SegmentHead({
    required this.device,
    required this.seqFrom,
    required this.seqTo,
    required List<LogRange> covers,
    required this.period,
    required this.hlcMax,
  }) : covers = List.unmodifiable(covers);

  /// The head of [events] written by [device] in [period]: [covers] is
  /// their ranges merged ([mergeRanges]).
  factory SegmentHead.of(
    String device,
    List<LogEvent> events, {
    required String period,
    List<LogRange>? covers,
  }) {
    if (events.isEmpty) throw ArgumentError.value(events, 'events', 'empty');
    final seqs = [for (final e in events) e.seq];
    return SegmentHead(
      device: device,
      seqFrom: seqs.reduce((a, b) => a < b ? a : b),
      seqTo: seqs.reduce((a, b) => a > b ? a : b),
      covers: covers ?? rangesOf(events),
      period: period,
      hlcMax: events.map((e) => e.hlc).reduce((a, b) => a > b ? a : b),
    );
  }

  /// Reads the kind fields of [head]; throws [FormatException].
  factory SegmentHead.fromExtra(Map<String, Object?> extra) {
    final seqFrom = extra['seqFrom'];
    final seqTo = extra['seqTo'];
    final covers = extra['covers'];
    if (seqFrom is! int || seqTo is! int || covers is! List) {
      throw const FormatException('bad segment head');
    }
    return SegmentHead(
      device: readStringField(extra, 'device'),
      seqFrom: seqFrom,
      seqTo: seqTo,
      covers: [for (final c in covers) LogRange.fromJson(c)],
      period: readStringField(extra, 'period'),
      hlcMax: Hlc.parse(readStringField(extra, 'hlcMax')),
    );
  }

  final String device;
  final int seqFrom;
  final int seqTo;
  final List<LogRange> covers;

  /// `YYYY-MM` (UTC) of the write ([periodOf]).
  final String period;
  final Hlc hlcMax;

  Map<String, Object?> toExtra() => {
        'device': device,
        'seqFrom': seqFrom,
        'seqTo': seqTo,
        'covers': [for (final c in covers) c.toJson()],
        'period': period,
        'hlcMax': hlcMax.encode(),
      };

  /// Whether every range of [other] lies within a range of this head.
  bool coversAll(SegmentHead other) =>
      other.covers.every((range) => covers.any((mine) => mine.contains(range)));
}

/// The ranges of [events], merged ([mergeRanges]).
List<LogRange> rangesOf(Iterable<LogEvent> events) =>
    mergeRanges([for (final e in events) LogRange(e.deviceId, e.seq, e.seq)]);

/// [ranges] merged per device where they overlap or touch, sorted by
/// device and `seqFrom`.
List<LogRange> mergeRanges(Iterable<LogRange> ranges) {
  final sorted = [...ranges]..sort((a, b) {
      final byDevice = a.deviceId.compareTo(b.deviceId);
      return byDevice != 0 ? byDevice : a.seqFrom.compareTo(b.seqFrom);
    });
  final out = <LogRange>[];
  for (final r in sorted) {
    final last = out.isEmpty ? null : out.last;
    if (last == null ||
        last.deviceId != r.deviceId ||
        r.seqFrom > last.seqTo + 1) {
      out.add(r);
      continue;
    }
    if (r.seqTo > last.seqTo) {
      out.last = LogRange(last.deviceId, last.seqFrom, r.seqTo);
    }
  }
  return out;
}

/// Whether [segment] is covered by one of [packs] (a pack is never covered
/// by itself: pass the others).
bool isCovered(SegmentHead segment, Iterable<SegmentHead> packs) =>
    packs.any((p) => p.coversAll(segment));

/// The UTC month of [hlc], `YYYY-MM`.
String periodOf(Hlc hlc) {
  final d = DateTime.fromMillisecondsSinceEpoch(hlc.wallMs, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';
}

/// [events] once per `(deviceId, seq)`, ordered by `(h, deviceId, seq)`.
List<LogEvent> dedupeEvents(Iterable<LogEvent> events) {
  final byId = <(String, int), LogEvent>{};
  for (final e in events) {
    byId.putIfAbsent((e.deviceId, e.seq), () => e);
  }
  return byId.values.toList()..sort(compareEvents);
}

/// Orders events by `(h, deviceId, seq)`.
int compareEvents(LogEvent a, LogEvent b) {
  final byHlc = a.hlc.compareTo(b.hlc);
  if (byHlc != 0) return byHlc;
  final byDevice = a.deviceId.compareTo(b.deviceId);
  return byDevice != 0 ? byDevice : a.seq.compareTo(b.seq);
}

/// One JSONL line: the canonical JSON of [json] ended by `\n`.
Uint8List encodeJsonLine(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode('${canonicalJson(json)}\n'));

/// The gzip of the concatenated [lines] ([encodeJsonLine]).
Uint8List gzipJsonLines(Iterable<Uint8List> lines) {
  final plain = BytesBuilder(copy: false);
  for (final line in lines) {
    plain.add(line);
  }
  return Uint8List.fromList(gzip.encode(plain.takeBytes()));
}

/// The JSON objects of a gzip JSONL body; blank lines are skipped. Throws
/// [FormatException].
List<Map<String, Object?>> decodeJsonLinesBody(Uint8List body) {
  final List<int> plain;
  try {
    plain = gzip.decode(body);
  } catch (e) {
    throw FormatException('bad gzip: $e');
  }
  return [
    for (final line in utf8.decode(plain).split('\n'))
      if (line.trim().isNotEmpty) decodeJsonObject(utf8.encode(line)),
  ];
}

/// The JSONL of [events]: one canonical JSON object per line, each line
/// ended by `\n`.
Uint8List encodeEventLines(Iterable<LogEvent> events) => Uint8List.fromList(
      utf8.encode(
        [for (final e in events) '${canonicalJson(e.json)}\n'].join(),
      ),
    );

/// The gzip of [encodeEventLines].
Uint8List encodeEventsBody(Iterable<LogEvent> events) =>
    Uint8List.fromList(gzip.encode(encodeEventLines(events)));

/// Reads a gzip JSONL body; blank lines are skipped. Throws
/// [FormatException].
List<LogEvent> decodeEventsBody(Uint8List body) =>
    [for (final json in decodeJsonLinesBody(body)) LogEvent.fromJson(json)];

/// A segment or pack read from an opened object.
typedef OpenedSegment = ({SegmentHead head, List<LogEvent> events});

/// The head fields and events of [object], a segment or pack; null when it
/// is none, a tombstone, or malformed.
OpenedSegment? readSegment(InnerObject object) {
  if (logOfKind(object.head.kind) == null || object.head.deleted) return null;
  try {
    final body = object.parts
        .where((p) => p.contentType == logBodyContentType)
        .firstOrNull;
    return (
      head: SegmentHead.fromExtra(object.head.extra),
      events: body == null ? const [] : decodeEventsBody(body.bytes),
    );
  } on FormatException {
    return null;
  }
}

/// A segment or pack of [log] holding [events], written as [versionId].
InnerObject segmentObject({
  required String log,
  required String itemId,
  required String collectionId,
  required Hlc versionId,
  required SegmentHead head,
  required List<LogEvent> events,
  bool pack = false,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: itemId,
        collectionId: collectionId,
        versionId: versionId,
        kind: pack ? packKind(log) : segKind(log),
        extra: head.toExtra(),
      ),
      parts: [
        ObjectPart(
          contentType: logBodyContentType,
          bytes: encodeEventsBody(events),
        ),
      ],
    );
