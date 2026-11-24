// Backend test for the compaction of the review log (#1382) against a real
// Stalwart: devices of one account, the key set up on A and unlocked on the
// others with the recovery key. A compacts while B syncs; a crash between
// the pack's APPEND and the expunge of its segments is repaired; the
// segments of a lost device (not seen for 90 days, or removed) are adopted
// by A, while B only hides them.
// Run via: task test-backend

import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_compactor.dart';
import 'package:sharedinbox/data/repositories/review_log_projector.dart';
import 'package:sharedinbox/data/repositories/review_repository_impl.dart';
import 'package:sharedinbox/data/repositories/review_uploader.dart';
import 'package:test/test.dart';

import 'key_device_harness.dart';

const _cardId = 'c1';

void main() {
  final pool = setUpKeyPool();
  late String recoveryKey;

  Future<_CompactingDevice> device() =>
      addKeyDevice(pool(), _CompactingDevice(pool().account));

  /// A with the key, then [others] devices that unlocked it.
  Future<List<_CompactingDevice>> devices(int others) async {
    final a = await device();
    recoveryKey = (await a.service.createKey(a.id) as KeyCreated).formatted;
    await a.store.waitForIdle();
    await a.listAndSync();
    final all = [a];
    for (var i = 0; i < others; i++) {
      final d = await device();
      await d.listAndSync();
      await d.service.unlockWithRecoveryKey(d.id, recoveryKey);
      await d.listAndSync();
      all.add(d);
    }
    return all;
  }

  Future<Set<String>> dataIds() async =>
      (await pool().rawMails(dataPath)).keys.toSet();

  test(
      'A compacts its 31 segments while B syncs: both read the same reviews '
      'and schedule, the server holds the pack only, B deleted nothing',
      () async {
    final [a, b] = await devices(1);
    await a.rateAndFlush(31);
    final segments = {
      for (final s in await a.log.segments(a.id, reviewLogName)) s.messageId,
    };
    expect(segments, hasLength(31));
    final steps = <String>[];
    b.onStep = steps.add;

    final (packs, _) = await (
      a.compactor.maybeCompact(a.id),
      b.listAndSync(),
    ).wait;
    await a.store.waitForIdle();
    await b.listAndSync();
    await a.listAndSync();
    await b.listAndSync();

    final pack = packs.single;
    final ids = await dataIds();
    expect(ids, contains(pack.messageId));
    expect(ids.intersection(segments), isEmpty);
    for (final d in [a, b]) {
      expect(await d.db.select(d.db.reviewLog).get(), hasLength(31));
      expect(await d.log.events(d.id, reviewLogName), hasLength(31));
    }
    expect(
      await b.reviews.observeSchedule(b.id, _cardId).first,
      await a.reviews.observeSchedule(a.id, _cardId).first,
    );
    expect(steps, isNot(contains('expunge')));
    expect(
      [for (final s in await b.log.segments(b.id, reviewLogName)) s.messageId],
      [pack.messageId],
    );
  });

  test(
      'a crash between the pack APPEND and the expunge: the next sync '
      'expunges the segments; an overlapping second pack hides the first',
      () async {
    final [a, b] = await devices(1);
    await a.rateAndFlush(3);
    final segments = {
      for (final s in await a.log.segments(a.id, reviewLogName)) s.messageId,
    };
    var crashes = 0;
    a.onStep = (step) {
      if (step != 'expunge') return;
      crashes++;
      throw StateError('crash before the expunge');
    };
    final period = periodOfTime(DateTime.now());

    final first = (await a.log.compact(a.id, reviewLogName, period)).single;
    await a.store.waitForIdle();
    expect(crashes, greaterThan(0));
    expect(await dataIds(), containsAll([first.messageId, ...segments]));
    // Pack and segments at once: each event once.
    await b.listAndSync();
    expect(await b.log.events(b.id, reviewLogName), hasLength(3));

    // The app starts again.
    a.onStep = null;
    await a.store.reopen(a.id);
    await a.listAndSync();
    expect((await dataIds()).intersection(segments), isEmpty);
    expect(await dataIds(), contains(first.messageId));

    await a.rateAndFlush(1);
    final second = (await a.log.compact(a.id, reviewLogName, period)).single;
    await a.store.waitForIdle();
    await b.listAndSync();

    final ids = await dataIds();
    expect(ids, contains(second.messageId));
    expect(ids, isNot(contains(first.messageId)));
    for (final d in [a, b]) {
      expect(
        [for (final s in await d.log.segments(d.id, reviewLogName)) s.kind],
        [packKind(reviewLogName)],
      );
      expect(await d.log.events(d.id, reviewLogName), hasLength(4));
      expect(await d.db.select(d.db.reviewLog).get(), hasLength(4));
    }
  });

  for (final removed in [false, true]) {
    test(
        removed
            ? 'A adopts the segments of a removed device at once, with '
                'generation 1; B keeps every event and deletes nothing'
            : 'A adopts the segments of a device not seen for 91 days; B '
                'keeps every event and deletes nothing', () async {
      final [a, b, lost] = await devices(2);
      await lost.rateAndFlush(2);
      final segments = {
        for (final s in await lost.log.segments(lost.id, reviewLogName))
          s.messageId,
      };
      await a.listAndSync();
      await b.listAndSync();
      final lostId = (await lost.store.clockFor(lost.id)).deviceId;
      final steps = <String>[];
      b.onStep = steps.add;
      if (removed) expect(await a.log.removeDevice(a.id, lostId), 1);
      final compactor = removed
          ? a.compactor
          : ReviewCompactor(
              MailObjectLog(
                a.db,
                a.store,
                now: () => DateTime.now().add(const Duration(days: 91)),
              ),
            );

      final pack = (await compactor.maybeCompact(a.id)).single;
      await a.store.waitForIdle();
      await b.listAndSync();
      await b.listAndSync();

      final head = readSegment((await a.store.open(pack))!)!.head;
      expect(head.device, (await a.store.clockFor(a.id)).deviceId);
      expect(head.covers.map((r) => r.deviceId), [lostId]);
      expect(head.generation, removed ? 1 : 0);
      final ids = await dataIds();
      expect(ids, contains(pack.messageId));
      expect(ids.intersection(segments), isEmpty);
      final onB = await b.log.events(b.id, reviewLogName);
      expect(onB, hasLength(2));
      expect(onB.map((e) => e.deviceId), everyElement(lostId));
      expect(await b.db.select(b.db.reviewLog).get(), hasLength(2));
      expect(steps, isNot(contains('expunge')));
    });
  }
}

/// A [KeyDevice] with the review projection, the review repository, its
/// uploader and the compactor on top.
class _CompactingDevice extends ProjectingKeyDevice {
  _CompactingDevice(super.account)
      : super(projectors: (db) => [ReviewLogProjector(db)]);

  late final log = MailObjectLog(db, store);
  late final uploader = ReviewUploader(db, log);
  late final compactor = ReviewCompactor(log);
  late final reviews = ReviewRepositoryImpl(
    db,
    store,
    deviceState: DeviceStateStore(db, store),
  );

  /// [count] ratings of [_cardId], each flushed as a segment of its own.
  Future<void> rateAndFlush(int count) async {
    for (var i = 0; i < count; i++) {
      await reviews.rate(id, _cardId, Rating.good);
      expect(await uploader.flush(id), 1);
      await store.waitForIdle();
    }
  }
}
