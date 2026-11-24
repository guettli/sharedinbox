import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';

/// The device-state key of the removed devices (#1382): `{deviceId:
/// generation}`, effective value account-global (5.4 item 4).
const removedDevicesKey = 'devices.removed';

/// Decides whose segments this device may compact (5.4 item 2): its own
/// ([OwnerOnlyCompaction]), and those of a lost or removed device
/// ([TakeoverCompaction], #1382).
abstract interface class CompactionAuthority {
  Future<bool> mayCompact(String accountId, String deviceId);
}

/// Only the owning device compacts its own segments.
class OwnerOnlyCompaction implements CompactionAuthority {
  const OwnerOnlyCompaction(this.ownDeviceId);

  /// The deviceId of this install.
  final String ownDeviceId;

  @override
  Future<bool> mayCompact(String accountId, String deviceId) async =>
      deviceId == ownDeviceId;
}

/// The owner compacts its own segments, and any device may adopt those of
/// a device in `devices.removed` ([MailObjectLog.removeDevice]) at once, or
/// of one not seen for [lostAfter] (90 days, #1382).
class TakeoverCompaction implements CompactionAuthority {
  TakeoverCompaction(
    this.db,
    this.store, {
    DateTime Function()? now,
    this.lostAfter = const Duration(days: 90),
  }) : now = now ?? DateTime.now;

  final AppDatabase db;
  final MailObjectStore store;
  final DateTime Function() now;
  final Duration lostAfter;

  @override
  Future<bool> mayCompact(String accountId, String deviceId) async {
    if (deviceId == (await store.clockFor(accountId)).deviceId) return true;
    if ((await removedDevicesOf(db, accountId)).containsKey(deviceId)) {
      return true;
    }
    final seen = await lastSeenOf(db, accountId, deviceId);
    if (seen == null) return false;
    return seen.wallMs < now().subtract(lostAfter).millisecondsSinceEpoch;
  }
}

/// The effective `devices.removed` map of [accountId]; invalid entries are
/// skipped.
Future<Map<String, int>> removedDevicesOf(
  AppDatabase db,
  String accountId,
) async {
  final value =
      (await effectiveDeviceStateOf(db, accountId))[removedDevicesKey];
  if (value is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in value.entries)
      if (key is String && value is int) key: value,
  };
}

/// The newest HLC of [deviceId] seen here: of its log events, device-state
/// values and object versions; null when it was never seen.
Future<Hlc?> lastSeenOf(
  AppDatabase db,
  String accountId,
  String deviceId,
) async {
  final events = db.mailObjectLogEvents.hlc.max();
  final states = db.mailObjectDeviceStates.hlc.max();
  final versions = db.mailObjects.versionId.max();
  final seen = [
    await (db.selectOnly(db.mailObjectLogEvents)
          ..addColumns([events])
          ..where(
            db.mailObjectLogEvents.accountId.equals(accountId) &
                db.mailObjectLogEvents.deviceId.equals(deviceId),
          ))
        .map((r) => r.read(events))
        .getSingle(),
    await (db.selectOnly(db.mailObjectDeviceStates)
          ..addColumns([states])
          ..where(
            db.mailObjectDeviceStates.accountId.equals(accountId) &
                db.mailObjectDeviceStates.deviceId.equals(deviceId),
          ))
        .map((r) => r.read(states))
        .getSingle(),
    // The deviceId of an encoded HLC starts at its 20th character.
    await (db.selectOnly(db.mailObjects)
          ..addColumns([versions])
          ..where(
            db.mailObjects.accountId.equals(accountId) &
                db.mailObjects.versionId.substr(20).equals(deviceId),
          ))
        .map((r) => r.read(versions))
        .getSingle(),
  ];
  Hlc? newest;
  for (final encoded in seen) {
    if (encoded == null) continue;
    try {
      final hlc = Hlc.parse(encoded);
      if (newest == null || hlc > newest) newest = hlc;
    } on FormatException {
      continue;
    }
  }
  return newest;
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
  /// Without an [authority], [TakeoverCompaction]; [deviceState] writes
  /// `devices.removed` ([removeDevice]).
  MailObjectLog(
    this.db,
    this.store, {
    CompactionAuthority? authority,
    DeviceStateStore? deviceState,
    DateTime Function()? now,
  })  : now = now ?? DateTime.now,
        authority = authority ?? TakeoverCompaction(db, store, now: now),
        deviceState = deviceState ?? DeviceStateStore(db, store);

  final AppDatabase db;
  final MailObjectStore store;
  final CompactionAuthority authority;
  final DeviceStateStore deviceState;

  /// The clock that tells a closed month from the open one.
  final DateTime Function() now;

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
    return appendStamped(accountId, log, collectionId, [
      for (final e in events)
        LogEvent(seq: clock.nextSeq(), hlc: clock.send(), json: e),
    ]);
  }

  /// Writes the events [stamped], already stamped with this device's `s`
  /// and `h` (e.g. ratings stored before, #1380), as one segment of [log]
  /// in [collectionId]. [device] is the `device` of the segment head
  /// (default: this device), e.g. the deviceId of an imported review
  /// history (#1385); the segment's versionId is still this device's.
  Future<MailObject> appendStamped(
    String accountId,
    String log,
    String collectionId,
    List<LogEvent> stamped, {
    String? device,
  }) async {
    if (stamped.isEmpty) {
      throw ArgumentError.value(stamped, 'stamped', 'empty');
    }
    final clock = await store.clockFor(accountId);
    final versionId = clock.send();
    return store.put(
      accountId,
      segmentObject(
        log: log,
        itemId: newItemId(),
        collectionId: collectionId,
        versionId: versionId,
        head: SegmentHead.of(
          device ?? clock.deviceId,
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
  /// the pack is confirmed. A pack of a closed month (before the one of
  /// [now]) is final: only segments are covered, so late ones get a pack of
  /// their own. [keep] drops events from the pack; its `covers` still
  /// lists them. Returns the packs; empty when there is nothing to cover.
  /// Throws [NotOwnerException] for a deviceId the [CompactionAuthority]
  /// refuses.
  Future<List<MailObject>> compact(
    String accountId,
    String log,
    String period, {
    Set<String>? deviceIds,
    bool Function(LogEvent event)? keep,
  }) async {
    final clock = await store.clockFor(accountId);
    final devices = deviceIds ?? {clock.deviceId};
    for (final d in devices) {
      if (!await authority.mayCompact(accountId, d)) {
        throw NotOwnerException(d);
      }
    }
    final closed = period.compareTo(periodOfTime(now())) < 0;
    final removed = await removedDevicesOf(db, accountId);
    final byCollection = <String, List<(MailObject, OpenedSegment)>>{};
    for (final row in await segments(accountId, log)) {
      if (closed && isPackKind(row.kind)) continue;
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
      final covers =
          mergeRanges([for (final c in covered) ...c.$2.head.covers]);
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
          covers: covers,
          generation: [
            for (final r in covers)
              if (r.deviceId != clock.deviceId) removed[r.deviceId] ?? 0,
          ].fold<int>(0, max),
        ),
        events: keep == null ? events : events.where(keep).toList(),
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

  /// Lists [deviceId] in `devices.removed` with the next generation, so
  /// any device may adopt its segments at once. Returns its generation; a
  /// device listed already keeps its own. Throws [ArgumentError] for this
  /// device, `NoWriteKeyException` when locked.
  Future<int> removeDevice(String accountId, String deviceId) async {
    final clock = await store.clockFor(accountId);
    if (deviceId == clock.deviceId) {
      throw ArgumentError.value(deviceId, 'deviceId', 'is this device');
    }
    final removed = await removedDevicesOf(db, accountId);
    if (removed[deviceId] case final generation?) return generation;
    final generation = removed.values.fold<int>(0, max) + 1;
    await deviceState.set(accountId, removedDevicesKey, {
      ...removed,
      deviceId: generation,
    });
    return generation;
  }
}
