import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_compaction_filter.dart';
import 'package:sharedinbox/data/repositories/review_compactor.dart';
import 'package:sharedinbox/data/repositories/review_log_projector.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';

import 'helpers/fake_object_account.dart';
import 'helpers/shared_keys_device.dart';
import 'helpers/stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;

/// A clock in a later month than every segment of the test.
DateTime _nextMonth() => DateTime.now().add(const Duration(days: 40));

/// One install with the review projection on the shared fake [server];
/// [now] is the clock of its log (and so of its compactor).
class _Device extends SharedKeysDevice {
  _Device(super.server, super.keys, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  final DateTime Function() now;

  @override
  late final List<MailObjectProjector> projectors = [ReviewLogProjector(db)];
  late final log = MailObjectLog(db, store, now: now);
  late final compactor = ReviewCompactor(log);

  static Future<_Device> open(
    StatefulFakeImapServer server,
    SharedCollectionKeys keys, {
    DateTime Function()? now,
  }) =>
      _Device(server, keys, now: now).init();

  Future<String> deviceId() async => (await store.clockFor(_acc)).deviceId;

  /// [count] segments of one review each.
  Future<void> writeSegments(int count) async {
    for (var i = 0; i < count; i++) {
      await log.append(_acc, reviewLogName, personalCollectionId, [
        {'op': 'review', 'c': 'c$i', 't': 1, 'r': 3, 'ms': 0},
      ]);
    }
    await store.waitForIdle();
  }

  Future<List<MailObject>> segments() =>
      store.rowsOfKind(_acc, segKind(reviewLogName));

  Future<List<MailObject>> packs() =>
      store.rowsOfKind(_acc, packKind(reviewLogName));
}

void main() {
  final fixture = setUpPersonalObjectServer();

  test('30 own segments of the open month stay; the 31st compacts them',
      () async {
    final a = await _Device.open(fixture.server, fixture.keys);
    await a.writeSegments(30);

    expect(await a.compactor.maybeCompact(_acc), isEmpty);
    expect(await a.segments(), hasLength(30));

    await a.writeSegments(1);
    final pack = (await a.compactor.maybeCompact(_acc)).single;
    await a.store.waitForIdle();

    expect(await a.segments(), isEmpty);
    expect(await a.packs(), [isA<MailObject>()]);
    expect(fixture.server.messagesIn(fakeObjectDataPath), hasLength(1));
    expect(
      readSegment((await a.store.open(pack))!)!.head.covers,
      [LogRange(await a.deviceId(), 1, 31)],
    );
    expect(await a.log.events(_acc, reviewLogName), hasLength(31));
    expect(await a.compactor.maybeCompact(_acc), isEmpty);
  });

  test('at the month rollover the previous month gets its pack', () async {
    final a = await _Device.open(fixture.server, fixture.keys);
    await a.writeSegments(2);
    expect(await a.compactor.maybeCompact(_acc), isEmpty);

    final later = ReviewCompactor(
      MailObjectLog(a.db, a.store, now: _nextMonth),
    );
    final pack = (await later.maybeCompact(_acc)).single;
    await a.store.waitForIdle();

    expect(await a.segments(), isEmpty);
    expect(
      readSegment((await a.store.open(pack))!)!.head.period,
      periodOfTime(DateTime.now()),
    );
    expect(fixture.server.messagesIn(fakeObjectDataPath), hasLength(1));
    expect(await later.maybeCompact(_acc), isEmpty);
  });

  test('a locked account (no write key) is a no-op', () async {
    final a = await _Device.open(fixture.server, fixture.keys);
    await a.writeSegments(31);
    final ids = {
      for (final m in fixture.server.messagesIn(fakeObjectDataPath))
        m.messageId,
    };
    fixture.keys.byCollection.clear();

    expect(await a.compactor.maybeCompact(_acc), isEmpty);
    await a.store.waitForIdle();

    expect(await a.segments(), hasLength(31));
    expect(
      {
        for (final m in fixture.server.messagesIn(fakeObjectDataPath))
          m.messageId,
      },
      ids,
    );
  });

  test(
      'the segments of a removed device are adopted at once, of another '
      'device not', () async {
    final a = await _Device.open(fixture.server, fixture.keys);
    final lost = await _Device.open(fixture.server, fixture.keys);
    final active = await _Device.open(fixture.server, fixture.keys);
    await lost.writeSegments(2);
    await active.writeSegments(1);
    await a.sync();
    final lostId = await lost.deviceId();
    expect(await a.compactor.maybeCompact(_acc), isEmpty);

    expect(await a.log.removeDevice(_acc, lostId), 1);
    final pack = (await a.compactor.maybeCompact(_acc)).single;
    await a.store.waitForIdle();

    final head = readSegment((await a.store.open(pack))!)!.head;
    expect(head.covers, [LogRange(lostId, 1, 2)]);
    expect(head.generation, 1);
    expect(head.device, await a.deviceId());
    // The active device's segment stays; the lost one's are gone.
    expect(await a.segments(), hasLength(1));
    expect(fixture.server.messagesIn(fakeObjectDataPath), hasLength(3));
    expect(await a.log.events(_acc, reviewLogName), hasLength(3));
  });

  group('ReviewCompactionFilter', () {
    late _Device a;
    late ReviewCompactionFilter filter;
    final hlc = Hlc(1000, 0, 'dev-x');

    LogEvent review(int seq, String cardId) => LogEvent(
          seq: seq,
          hlc: hlc,
          json: {'op': 'review', 'c': cardId, 't': 1, 'r': 3, 'ms': 0},
        );
    LogEvent undo(int seq, int ref) => LogEvent(
          seq: seq,
          hlc: hlc,
          json: {
            'op': 'undo',
            'ref': ['dev-x', ref],
          },
        );

    /// A deleted `c1` whose winning tombstone is the row `<t1>`.
    Future<void> deletedCard({required bool synced}) async {
      await a.db.into(a.db.cards).insert(
            CardsCompanion.insert(
              accountId: _acc,
              cardId: 'c1',
              collectionId: 'deck-1',
              sourceItemHmac: 'hm-c1',
              sourceKind: CardSourceKind.doc.name,
              h: 'v-tomb',
              deleted: const Value(true),
            ),
          );
      await a.db.into(a.db.mailObjects).insert(
            MailObjectsCompanion.insert(
              accountId: _acc,
              folder: MailObjectFolder.data.name,
              messageId: '<t1>',
              itemHmac: const Value('hm-c1'),
              versionId: const Value('v-tomb'),
              pendingUpload: Value(!synced),
              serverId: Value(synced ? '1:7' : null),
            ),
          );
      final events = [review(1, 'c1'), undo(2, 1), review(3, 'c2')];
      for (final e in events) {
        await a.db.into(a.db.reviewLog).insert(
              reviewLogCompanion(_acc, CardEvent.fromLogEvent(e)!),
            );
      }
    }

    setUp(() async {
      a = await _Device.open(fixture.server, fixture.keys);
      filter = ReviewCompactionFilter(a.db);
    });

    test('a tombstone still pending keeps the events', () async {
      await deletedCard(synced: false);
      final keep = await filter.load(_acc);

      expect(await filter.syncedTombstones(_acc), isEmpty);
      expect(
        [review(1, 'c1'), undo(2, 1), review(3, 'c2')].every(keep),
        isTrue,
      );
    });

    test(
        'a synced tombstone drops the reviews of the card and the undos of '
        'those reviews', () async {
      await deletedCard(synced: true);
      final keep = await filter.load(_acc);

      expect(await filter.syncedTombstones(_acc), {'c1'});
      expect(keep(review(1, 'c1')), isFalse);
      expect(keep(undo(2, 1)), isFalse);
      expect(keep(review(3, 'c2')), isTrue);
      expect(keep(undo(4, 3)), isTrue);
      // Local rows stay.
      expect(await a.db.select(a.db.reviewLog).get(), hasLength(3));
    });
  });
}
