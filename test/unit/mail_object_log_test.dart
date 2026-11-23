import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';

import 'db_test_helper.dart';
import 'helpers/mail_object_rig.dart';

const _log = 'review';

/// The month the segments of a test are written in.
String get _period =>
    periodOf(Hlc(DateTime.now().millisecondsSinceEpoch, 0, 'any'));

/// Allows every device: the #1382 extension point.
class _AnyDevice implements CompactionAuthority {
  @override
  bool mayCompact(String accountId, String deviceId) => true;
}

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
}
