import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';

import 'db_test_helper.dart';
import 'encrypted_objects/test_helpers.dart';
import 'helpers/mail_object_rig.dart';

const _log = 'review';

/// The month the segments of a test are written in.
String get _period =>
    periodOf(Hlc(DateTime.now().millisecondsSinceEpoch, 0, 'any'));

/// Allows every device: the #1382 extension point.
class _AnyDevice implements CompactionAuthority {
  @override
  Future<bool> mayCompact(String accountId, String deviceId) async => true;
}

/// A clock in a later month than every segment of the test: their month
/// is closed.
DateTime _nextMonth() => DateTime.now().add(const Duration(days: 40));

Future<String> _deviceOf(RigDevice d) async =>
    (await d.store.clockFor(d.accountId)).deviceId;

/// The head of [pack] as [d] reads it.
Future<SegmentHead> _headOf(RigDevice d, MailObject pack) async =>
    readSegment((await d.store.open(pack))!)!.head;

void main() {
  setUpAll(configureSqliteForTests);

  for (final transport in ObjectTransport.values) {
    group(transport.name, () {
      test(
          'segments are compacted into one pack; the other device reads the '
          'same events and uploads nothing again', () async {
        final rig = ObjectRig(transport);
        final a = await rig.device();
        final b = await rig.device();
        await a.appendEvents(_log, [1, 2]);
        await a.appendEvents(_log, [3]);
        await a.appendEvents(_log, [4]);
        expect(rig.dataIds(), hasLength(3));
        await b.listAndSync();
        expect(await b.eventNs(_log), [1, 2, 3, 4]);
        final uploads = rig.uploadCount;

        final packs = await a.log.compact(a.accountId, _log, _period);
        await a.store.waitForIdle();

        expect(rig.dataIds(), [packs.single.messageId]);
        expect(rig.uploadCount, uploads + 1);
        expect(
          [for (final s in await a.log.segments(a.accountId, _log)) s.kind],
          [packKind(_log)],
        );
        expect(await a.eventNs(_log), [1, 2, 3, 4]);
        await b.sync();
        await b.sync();
        expect(await b.eventNs(_log), [1, 2, 3, 4]);
        expect(rig.uploadCount, uploads + 1);
        expect(b.events(), isNot(contains('mos.vanished_reupload')));
        expect(
          [for (final r in await b.rows()) r.messageId],
          [packs.single.messageId],
        );
        // Nothing left to compact.
        expect(await a.log.compact(a.accountId, _log, _period), isEmpty);
      });

      test('a delete waits until the pack is confirmed', () async {
        final rig = ObjectRig(transport);
        final a = await rig.device();
        await a.appendEvents(_log, [1]);
        await a.appendEvents(_log, [2]);
        final segments = rig.dataIds();
        a.onStep = (step) {
          if (step == 'append' || step == 'import') {
            throw StateError('refused');
          }
        };

        final pack = (await a.log.compact(a.accountId, _log, _period)).single;
        await a.store.waitForIdle();

        expect(rig.dataIds(), segments);
        expect(a.events(), contains('mos.push.failed'));
        for (final id in segments) {
          final row = (await a.row(id))!;
          expect(row.pendingDelete, isTrue);
          expect(row.coveredBy, pack.messageId);
        }
        a.onStep = null;
        await a.sync();
        expect(rig.dataIds(), [pack.messageId]);
        expect(await a.eventNs(_log), [1, 2]);
      });

      test(
          'a crash between the pack upload and the delete is repaired after '
          'a restart; one pack, segments gone', () async {
        final rig = ObjectRig(transport);
        final a = await rig.device();
        final b = await rig.device();
        await a.appendEvents(_log, [1]);
        await a.appendEvents(_log, [2]);
        a.onStep = (step) {
          if (step == rig.created) throw StateError('crash');
        };

        final pack = (await a.log.compact(a.accountId, _log, _period)).single;
        await a.store.waitForIdle();
        expect(rig.dataIds(), hasLength(3));
        // Pack and segments at once: each event once.
        await b.listAndSync();
        expect(await b.eventNs(_log), [1, 2]);

        final restarted = a.restart();
        await restarted.sync();

        expect(rig.dataIds(), [pack.messageId]);
        expect(rig.uploadCount, 3);
        expect(await restarted.eventNs(_log), [1, 2]);
        await b.sync();
        expect(await b.eventNs(_log), [1, 2]);
      });

      test(
          'a covered segment that vanishes is dropped; an uncovered one is '
          'uploaded again', () async {
        final rig = ObjectRig(transport);
        final a = await rig.device();
        final b = await rig.device();
        await a.appendEvents(_log, [1]);
        final kept = rig.dataIds().single;
        await b.listAndSync();

        rig.removeElsewhere(kept);
        await a.sync();
        expect(rig.dataIds(), [kept]);
        expect(a.events(), contains('mos.vanished_reupload'));

        await a.appendEvents(_log, [2]);
        await a.log.compact(a.accountId, _log, _period);
        await a.store.waitForIdle();
        final uploads = rig.uploadCount;
        await b.sync();
        expect(rig.uploadCount, uploads);
        expect(b.events(), isNot(contains('mos.vanished_reupload')));
        expect(await b.eventNs(_log), [1, 2]);
      });

      test('the background store compacts locally but never deletes', () async {
        final rig = ObjectRig(transport);
        final a = await rig.device();
        await a.appendEvents(_log, [1]);
        await a.appendEvents(_log, [2]);
        final segments = rig.dataIds();
        final bg = a.restart(background: true);

        await bg.log.compact(bg.accountId, _log, _period);
        await bg.sync();

        expect(rig.dataIds(), segments);
        expect(await bg.eventNs(_log), [1, 2]);
      });
    });
  }

  test('a foreign deviceId is refused by the owner rule', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    await a.appendEvents(_log, [1]);
    await expectLater(
      a.log.compact(a.accountId, _log, _period, deviceIds: {'someone-else'}),
      throwsA(isA<NotOwnerException>()),
    );
  });

  test(
      'only own segments are compacted by default; an authority that allows '
      'the foreign device lets it be compacted (#1382)', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    final b = await rig.device();
    await a.appendEvents(_log, [1]);
    await a.appendEvents(_log, [2]);
    await b.listAndSync();
    final aDevice = (await a.store.clockFor(a.accountId)).deviceId;

    expect(await b.log.compact(b.accountId, _log, _period), isEmpty);

    final adopting = MailObjectLog(b.db, b.store, authority: _AnyDevice());
    final pack = (await adopting.compact(
      b.accountId,
      _log,
      _period,
      deviceIds: {aDevice},
    ))
        .single;
    await b.store.waitForIdle();

    expect(rig.dataIds(), [pack.messageId]);
    await a.sync();
    expect(await a.eventNs(_log), [1, 2]);
    expect([for (final r in await a.rows()) r.messageId], [pack.messageId]);
  });

  test(
      'appendStamped(device:) writes the head of another deviceId; the '
      'versionId stays own, and the owner rule does not compact it (#1385)',
      () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    const imported = 'import:abc';
    final row = await a.log.appendStamped(
      a.accountId,
      _log,
      testDeckKey.collectionId,
      [
        for (final seq in [1700000000000, 1700000005000])
          LogEvent(seq: seq, hlc: Hlc(seq, 0, imported), json: {'n': seq}),
      ],
      device: imported,
    );
    await a.store.waitForIdle();

    final segment = readSegment((await a.store.open(row))!)!;
    expect(segment.head.device, imported);
    expect(segment.head.covers, [
      const LogRange(imported, 1700000000000, 1700000000000),
      const LogRange(imported, 1700000005000, 1700000005000),
    ]);
    final own = (await a.store.clockFor(a.accountId)).deviceId;
    expect(Hlc.parse(row.versionId!).deviceId, own);
    expect(
      [for (final e in await a.log.events(a.accountId, _log)) e.deviceId],
      [imported, imported],
    );
    expect(await a.log.compact(a.accountId, _log, _period), isEmpty);
  });

  test('two packs over the same ranges: the newer stays, events once',
      () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    await a.appendEvents(_log, [1]);
    await a.appendEvents(_log, [2]);
    final first = (await a.log.compact(a.accountId, _log, _period)).single;
    await a.store.waitForIdle();
    final opened = (await a.store.open(first))!;
    final segment = readSegment(opened)!;
    final clock = await a.store.clockFor(a.accountId);

    final second = await a.store.putCovering(
      a.accountId,
      segmentObject(
        log: _log,
        itemId: 'pack-2',
        collectionId: opened.head.collectionId,
        versionId: clock.send(),
        head: segment.head,
        events: segment.events,
        pack: true,
      ),
      covered: const [],
    );
    await a.store.waitForIdle();

    expect(
      [for (final s in await a.log.segments(a.accountId, _log)) s.messageId],
      [second.messageId],
    );
    expect(rig.dataIds(), [second.messageId]);
    expect(await a.eventNs(_log), [1, 2]);
  });

  test('seq goes past own events after a restart whose high-water mark lags',
      () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    await a.appendEvents(_log, [1, 2, 3]);
    // The high-water marks lost the seqs (a write that did not reach them).
    final identity = await a.db.select(a.db.mailObjectDevices).getSingle();
    await a.db
        .update(a.db.mailObjectDevices)
        .write(const MailObjectDevicesCompanion(seqHigh: Value(0)));
    await a.storage.write(
      key: DeviceIdentityResolver.markerKey(a.accountId),
      value: jsonEncode(
        DeviceIdentity(
          deviceId: identity.deviceId,
          hlcHigh:
              identity.hlcHigh == null ? null : Hlc.parse(identity.hlcHigh!),
        ).toJson(),
      ),
      access: SecureStorageAccess.afterFirstUnlockThisDevice,
    );

    final restarted = a.restart();
    await restarted.appendEvents(_log, [4]);

    final seqs = [
      for (final e in await restarted.log.events(a.accountId, _log)) e.seq,
    ];
    expect(seqs, [1, 2, 3, 4]);
    expect(
      (await restarted.store.clockFor(a.accountId)).deviceId,
      identity.deviceId,
    );
  });

  group('closed months (#1382)', () {
    test('an open month re-packs its pack and the new segments into one',
        () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();
      await a.appendEvents(_log, [1]);
      await a.appendEvents(_log, [2]);
      final first = (await a.log.compact(a.accountId, _log, _period)).single;
      await a.store.waitForIdle();
      await a.appendEvents(_log, [3]);

      final second = (await a.log.compact(a.accountId, _log, _period)).single;
      await a.store.waitForIdle();

      expect(rig.dataIds(), [second.messageId]);
      // Covered, then deleted with the segments.
      expect(await a.row(first.messageId), isNull);
      final device = await _deviceOf(a);
      expect((await _headOf(a, second)).covers, [LogRange(device, 1, 3)]);
      expect(await a.eventNs(_log), [1, 2, 3]);
    });

    test(
        'a closed month never covers its pack: a late segment gets an extra '
        'pack and the old pack stays', () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();
      final closed = MailObjectLog(a.db, a.store, now: _nextMonth);
      await a.appendEvents(_log, [1]);
      await a.appendEvents(_log, [2]);
      final first = (await closed.compact(a.accountId, _log, _period)).single;
      await a.store.waitForIdle();
      await a.appendEvents(_log, [3]);
      await a.appendEvents(_log, [4]);

      final extra = (await closed.compact(a.accountId, _log, _period)).single;
      await a.store.waitForIdle();

      expect(
        rig.dataIds(),
        unorderedEquals([first.messageId, extra.messageId]),
      );
      final device = await _deviceOf(a);
      expect((await _headOf(a, first)).covers, [LogRange(device, 1, 2)]);
      expect((await _headOf(a, extra)).covers, [LogRange(device, 3, 4)]);
      expect(
        {for (final s in await a.log.segments(a.accountId, _log)) s.messageId},
        {first.messageId, extra.messageId},
      );
      expect(await a.eventNs(_log), [1, 2, 3, 4]);
      // Only packs are left, and they are final.
      expect(await closed.compact(a.accountId, _log, _period), isEmpty);
    });
  });

  test(
      'keep drops events from the pack; its covers still lists them '
      '(#1382)', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    final b = await rig.device();
    await a.appendEvents(_log, [1, 2]);
    await a.appendEvents(_log, [3]);

    final pack = (await a.log.compact(
      a.accountId,
      _log,
      _period,
      keep: (e) => e.json['n'] != 2,
    ))
        .single;
    await a.store.waitForIdle();
    await b.listAndSync();

    final opened = readSegment((await b.store.open(pack))!)!;
    expect([for (final e in opened.events) e.json['n']], [1, 3]);
    expect(opened.head.covers, [LogRange(await _deviceOf(a), 1, 3)]);
    expect(rig.dataIds(), [pack.messageId]);
    expect(await b.eventNs(_log), [1, 3]);
  });

  group('adoption (#1382)', () {
    test('removeDevice: generations 1, then 2; a repeat keeps its own',
        () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();

      expect(await a.log.removeDevice(a.accountId, 'lost-1'), 1);
      expect(await a.log.removeDevice(a.accountId, 'lost-2'), 2);
      expect(await a.log.removeDevice(a.accountId, 'lost-1'), 1);

      expect(
        await removedDevicesOf(a.db, a.accountId),
        {'lost-1': 1, 'lost-2': 2},
      );
      expect(
        () async => a.log.removeDevice(a.accountId, await _deviceOf(a)),
        throwsArgumentError,
      );
    });

    test(
        'the takeover authority: own device, a removed device, and one not '
        'seen for 91 but not 89 days', () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();
      final lost = await rig.device();
      await lost.appendEvents(_log, [1]);
      await a.listAndSync();
      final lostId = await _deviceOf(lost);
      TakeoverCompaction after(int days) => TakeoverCompaction(
            a.db,
            a.store,
            now: () => DateTime.now().add(Duration(days: days)),
          );

      expect(await after(0).mayCompact(a.accountId, await _deviceOf(a)), true);
      expect(await after(0).mayCompact(a.accountId, lostId), false);
      expect(await after(89).mayCompact(a.accountId, lostId), false);
      expect(await after(91).mayCompact(a.accountId, lostId), true);
      expect(await after(91).mayCompact(a.accountId, 'never-seen'), false);

      await a.log.removeDevice(a.accountId, lostId);
      expect(await after(0).mayCompact(a.accountId, lostId), true);
    });

    test(
        'the adopter packs a removed device with its generation and deletes '
        'its segments; a third device only hides them', () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();
      final c = await rig.device();
      final lost = await rig.device();
      await lost.appendEvents(_log, [1]);
      await lost.appendEvents(_log, [2]);
      final segments = rig.dataIds();
      await a.listAndSync();
      await c.listAndSync();
      final lostId = await _deviceOf(lost);
      await a.log.removeDevice(a.accountId, lostId);
      await a.store.waitForIdle();
      // The adopter's deletes fail until it syncs again.
      a.onStep = (step) {
        if (step == 'expunge') throw StateError('refused');
      };

      final pack = (await a.log.compact(
        a.accountId,
        _log,
        _period,
        deviceIds: {await _deviceOf(a), lostId},
      ))
          .single;
      await a.store.waitForIdle();

      expect((await _headOf(a, pack)).generation, 1);
      expect((await _headOf(a, pack)).covers, [LogRange(lostId, 1, 2)]);
      for (final id in segments) {
        expect((await a.row(id))!.pendingDelete, isTrue);
      }
      await c.sync();
      for (final id in segments) {
        final row = (await c.row(id))!;
        expect(row.coveredBy, pack.messageId);
        expect(row.pendingDelete, isFalse);
      }
      await c.sync();
      expect(rig.dataIds(), containsAll(segments));
      expect(await c.eventNs(_log), [1, 2]);

      a.onStep = null;
      await a.sync();
      expect(rig.dataIds(), contains(pack.messageId));
      expect(rig.dataIds(), isNot(contains(anyOf(segments))));
      await c.sync();
      expect(await c.eventNs(_log), [1, 2]);
      expect(
        [for (final r in await c.rows()) r.kind],
        contains(packKind(_log)),
      );
    });

    test(
        'of two packs with the same coverage the higher generation wins over '
        'the newer one', () async {
      final rig = ObjectRig(ObjectTransport.imap);
      final a = await rig.device();
      await a.appendEvents(_log, [1]);
      await a.appendEvents(_log, [2]);
      final segment = readSegment(
        (await a.store.open(
          (await a.log.compact(a.accountId, _log, _period)).single,
        ))!,
      )!;
      await a.store.waitForIdle();
      final clock = await a.store.clockFor(a.accountId);
      Future<MailObject> pack(String itemId, int generation) =>
          a.store.putCovering(
            a.accountId,
            segmentObject(
              log: _log,
              itemId: itemId,
              collectionId: testDeckKey.collectionId,
              versionId: clock.send(),
              head: SegmentHead(
                device: segment.head.device,
                seqFrom: segment.head.seqFrom,
                seqTo: segment.head.seqTo,
                covers: segment.head.covers,
                period: segment.head.period,
                hlcMax: segment.head.hlcMax,
                generation: generation,
              ),
              events: segment.events,
              pack: true,
            ),
            covered: const [],
          );

      final adopted = await pack('pack-gen-1', 1);
      await pack('pack-gen-0', 0);
      await a.store.waitForIdle();

      expect(
        [for (final s in await a.log.segments(a.accountId, _log)) s.messageId],
        [adopted.messageId],
      );
      expect(rig.dataIds(), [adopted.messageId]);
      expect(await a.eventNs(_log), [1, 2]);
    });
  });
}
