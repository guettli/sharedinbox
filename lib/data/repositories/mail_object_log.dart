import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Decides whose segments this device may compact (5.4 item 2). The owner
/// rule is [OwnerOnlyCompaction]; #1382 adds the 90-day takeover and the
/// adoption of a lost device's segments.
abstract interface class CompactionAuthority {
  bool mayCompact(String accountId, String deviceId);
}

/// Only the owning device compacts its own segments.
class OwnerOnlyCompaction implements CompactionAuthority {
  const OwnerOnlyCompaction(this.ownDeviceId);

  /// The deviceId of this install.
  final String ownDeviceId;

  @override
  bool mayCompact(String accountId, String deviceId) => deviceId == ownDeviceId;
}

/// Thrown when a compaction would cover segments of a device the
/// [CompactionAuthority] refuses.
class NotOwnerException implements Exception {
  const NotOwnerException(this.deviceId);

  final String deviceId;

  @override
  String toString() =>
      'NotOwnerException: may not compact the segments of "$deviceId"';
}

/// Log segments and packs over a [MailObjectStore] (#1372): [append] writes
/// a segment, [compact] replaces this device's segments of a month by one
/// pack, and the readers see every event once, from the projection the
/// store keeps ([MailObjectLogEvents]). Log-specific event types (review,
/// undo) come with their features (#1380).
class MailObjectLog {
  /// Without an [authority], [OwnerOnlyCompaction] of this install.
  MailObjectLog(this.db, this.store, {CompactionAuthority? authority})
      : _authority = authority;

  final AppDatabase db;
  final MailObjectStore store;
  final CompactionAuthority? _authority;

  /// Writes [events] (their own fields; `s` and `h` are set here) as one
  /// segment of [log] in [collectionId].
  Future<MailObject> append(
    String accountId,
    String log,
    String collectionId,
    List<Map<String, Object?>> events,
  ) async {
    if (events.isEmpty) throw ArgumentError.value(events, 'events', 'empty');
    final clock = await store.clockFor(accountId);
    final stamped = [
      for (final e in events)
        LogEvent(seq: clock.nextSeq(), hlc: clock.send(), json: e),
    ];
    final versionId = clock.send();
    return store.put(
      accountId,
      segmentObject(
        log: log,
        itemId: newItemId(),
        collectionId: collectionId,
        versionId: versionId,
        head: SegmentHead.of(
          clock.deviceId,
          stamped,
          period: periodOf(versionId),
        ),
        events: stamped,
      ),
    );
  }

  /// The segments and packs of [log] no pack covers, oldest first.
  Future<List<MailObject>> segments(String accountId, String log) async => [
        ...await store.rowsOfKind(accountId, segKind(log)),
        ...await store.rowsOfKind(accountId, packKind(log)),
      ]..sort((a, b) => a.versionId!.compareTo(b.versionId!));

  /// Every event of [log] seen here, once per `(deviceId, seq)`, ordered by
  /// `(h, deviceId, seq)`.
  Future<List<LogEvent>> events(String accountId, String log) =>
      _eventsQuery(accountId, log).get().then(_toEvents);

  Stream<List<LogEvent>> watchEvents(String accountId, String log) =>
      _eventsQuery(accountId, log).watch().map(_toEvents);

  SimpleSelectStatement<$MailObjectLogEventsTable, MailObjectLogEventRow>
      _eventsQuery(String accountId, String log) =>
          db.select(db.mailObjectLogEvents)
            ..where((t) => t.accountId.equals(accountId) & t.log.equals(log))
            ..orderBy([
              (t) => OrderingTerm.asc(t.hlc),
              (t) => OrderingTerm.asc(t.deviceId),
              (t) => OrderingTerm.asc(t.seq),
            ]);

  static List<LogEvent> _toEvents(List<MailObjectLogEventRow> rows) => [
        for (final r in rows)
          LogEvent.fromJson(jsonDecode(r.eventJson) as Map<String, Object?>),
      ];

  /// Replaces the uncovered segments and packs of [log] written in
  /// [period] (`YYYY-MM`) by [deviceIds] (default: this device) with one
  /// pack per collection, then the store deletes them on the server once
  /// the pack is confirmed. Returns the packs; empty when there is nothing
  /// to cover. Throws [NotOwnerException] for a deviceId the
  /// [CompactionAuthority] refuses.
  Future<List<MailObject>> compact(
    String accountId,
    String log,
    String period, {
    Set<String>? deviceIds,
  }) async {
    final clock = await store.clockFor(accountId);
    final authority = _authority ?? OwnerOnlyCompaction(clock.deviceId);
    final devices = deviceIds ?? {clock.deviceId};
    for (final d in devices) {
      if (!authority.mayCompact(accountId, d)) throw NotOwnerException(d);
    }
    final byCollection = <String, List<(MailObject, OpenedSegment)>>{};
    for (final row in await segments(accountId, log)) {
      final object = await store.open(row);
      if (object == null) continue;
      final segment = readSegment(object);
      if (segment == null || segment.head.period != period) continue;
      if (!segment.head.covers.every((r) => devices.contains(r.deviceId))) {
        continue;
      }
      (byCollection[object.head.collectionId] ??= []).add((row, segment));
    }
    final packs = <MailObject>[];
    for (final MapEntry(key: collectionId, value: covered)
        in byCollection.entries) {
      // A lone pack is compacted already.
      if (covered.length == 1 && isPackKind(covered.single.$1.kind)) continue;
      final events = dedupeEvents([for (final c in covered) ...c.$2.events]);
      final versionId = clock.send();
      final pack = segmentObject(
        log: log,
        itemId: newItemId(),
        collectionId: collectionId,
        versionId: versionId,
        head: SegmentHead.of(
          clock.deviceId,
          events,
          period: period,
          covers: mergeRanges([for (final c in covered) ...c.$2.head.covers]),
        ),
        events: events,
        pack: true,
      );
      packs.add(
        await store.putCovering(
          accountId,
          pack,
          covered: [for (final c in covered) c.$1.messageId],
        ),
      );
    }
    return packs;
  }
}
