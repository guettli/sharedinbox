import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/card_replay.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';
import 'package:sharedinbox/core/flashcards/review_upload_scheduler.dart';
import 'package:sharedinbox/core/flashcards/study_queue.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/review_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_schedule_writer.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/review_log_projector.dart';
import 'package:sharedinbox/data/repositories/review_repository_impl.dart';
import 'package:sharedinbox/data/repositories/review_uploader.dart';

import 'db_test_helper.dart';
import 'flashcards/fake_time_zones.dart';
import 'helpers/fake_object_account.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;
const _dataPath = fakeObjectDataPath;

/// Records what the repository tells the upload scheduler.
class _RecordingScheduler extends ReviewUploadScheduler {
  _RecordingScheduler()
      : super(flush: (_) async {}, pendingAccounts: () async => const []);

  final ratedCalls = <(String, int)>[];
  final sessions = <String>[];

  @override
  void rated(String accountId, int pending) =>
      ratedCalls.add((accountId, pending));

  @override
  void endSession(String accountId) => sessions.add(accountId);
}

/// One install with the card and review projections on the shared fake
/// [server]. While [offline], every connection attempt throws; [connects]
/// counts them all.
class _ReviewDevice {
  _ReviewDevice(
    this.server,
    this.keys, {
    AppDatabase? db,
    FakeSecureStorage? storage,
  })  : db = db ?? openTestDatabase(),
        storage = storage ?? FakeSecureStorage();

  final StatefulFakeImapServer server;
  final SharedCollectionKeys keys;
  final AppDatabase db;
  final FakeSecureStorage storage;
  bool offline = false;
  int connects = 0;
  DateTime now = DateTime.utc(2026, 11, 2, 12);

  Future<StatefulFakeImapClient> _connect(
    Object _,
    Object __,
    Object ___,
  ) async {
    connects++;
    if (offline) throw StateError('offline');
    return server.connect();
  }

  late final accounts = AccountRepositoryImpl(db, storage);
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (a, b, c) => _connect(a, b, c),
    namespace: _namespace,
  );
  late final store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    storage,
    imapConnect: (a, b, c) => _connect(a, b, c),
    namespace: _namespace,
    keyLookup: (_, keyId) => keys.lookup(keyId),
    writeKey: (_, collectionId) => keys.byCollection[collectionId],
    projectors: [
      CardDocProjector(db),
      CardBatchProjector(db),
      ReviewLogProjector(db),
    ],
  );
  late final log = MailObjectLog(db, store);
  late final uploader = ReviewUploader(db, log);
  late final deviceState = DeviceStateStore(db, store);
  late final schedules = CardScheduleWriter(db);
  final scheduler = _RecordingScheduler();
  late final repo = ReviewRepositoryImpl(
    db,
    store,
    deviceState: deviceState,
    schedules: schedules,
    uploads: scheduler,
    now: () => now,
  );

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_ReviewDevice> open(
    StatefulFakeImapServer server,
    SharedCollectionKeys keys,
  ) async {
    final device = _ReviewDevice(server, keys);
    addTearDown(() async {
      await device.store.waitForIdle();
      await device.db.close();
    });
    await device.accounts.addAccount(fakeObjectAccount, 'pw');
    return device;
  }

  /// A new store on the same database and secure storage (an app restart).
  _ReviewDevice restart() =>
      _ReviewDevice(server, keys, db: db, storage: storage);

  Future<void> sync() async {
    await mailboxes.syncMailboxes(_acc);
    await store.sync(_acc);
    await store.waitForIdle();
  }

  Future<List<ReviewLogRow>> reviewRows() =>
      (db.select(db.reviewLog)..orderBy([(t) => OrderingTerm.asc(t.h)])).get();

  Future<CardSchedule?> schedule(String cardId) =>
      repo.observeSchedule(_acc, cardId).first;

  Future<String?> paramsKey(String cardId) async =>
      (await (db.select(db.cardSchedules)
                ..where((t) => t.cardId.equals(cardId)))
              .getSingleOrNull())
          ?.paramsKey;

  /// A `Cards` row of [cardId] in [deckId], as the card projection writes.
  Future<void> addCard(String cardId, String deckId) =>
      db.into(db.cards).insert(
            CardsCompanion.insert(
              accountId: _acc,
              cardId: cardId,
              collectionId: deckId,
              sourceItemHmac: 'hm-$cardId',
              sourceKind: CardSourceKind.doc.name,
              h: 'h',
            ),
          );
}

LogEvent _wire(CardEvent e) =>
    LogEvent(seq: e.seq, hlc: Hlc.parse(e.h), json: e.toJson());

void main() {
  late StatefulFakeImapServer server;
  late SharedCollectionKeys keys;
  setUpFakeObjectServer(
    (s, k) => (server, keys) = (s, k),
    collections: const [personalCollectionId],
  );

  test(
      'a rating with a transport that fails every call: one pending event, '
      'the schedule, and not a single connection', () async {
    final a = await _ReviewDevice.open(server, keys);
    a.offline = true;
    a.connects = 0;

    final event = await a.repo.rate(_acc, 'c1', Rating.good, durationMs: 1200);
    await a.store.waitForIdle();

    expect(a.connects, 0);
    final row = (await a.reviewRows()).single;
    expect(row.segmentItemId, isNull);
    expect(row.op, 'review');
    expect(row.cardId, 'c1');
    expect(row.rating, 3);
    expect(row.durationMs, 1200);
    expect(row.t, a.now.millisecondsSinceEpoch);
    expect(event.deviceId, (await a.store.clockFor(_acc)).deviceId);
    expect(event.seq, row.seq);
    final schedule = await a.schedule('c1');
    expect(schedule, replayCard('c1', [event]));
    expect(schedule!.reps, 1);
    expect(a.scheduler.ratedCalls, [(_acc, 1)]);

    await a.repo.rate(_acc, 'c1', Rating.again);
    expect(a.connects, 0);
    expect((await a.schedule('c1'))!.reps, 2);
    expect(a.scheduler.ratedCalls.last, (_acc, 2));
    expect(await a.repo.pendingCount(_acc), 2);
    expect(await a.uploader.pendingAccounts(), [_acc]);

    a.repo.endSession(_acc);
    expect(a.scheduler.sessions, [_acc]);
  });

  test(
      'an undo cancels the review; a card without a counted review has no '
      'schedule', () async {
    final a = await _ReviewDevice.open(server, keys);
    final first = await a.repo.rate(_acc, 'c1', Rating.good);
    await a.repo.rate(_acc, 'c1', Rating.easy);
    final undo =
        await a.repo.undo(_acc, deviceId: first.deviceId, seq: first.seq);

    expect(undo.refDeviceId, first.deviceId);
    expect(undo.refSeq, first.seq);
    expect((await a.schedule('c1'))!.reps, 1);
    final rows = await a.reviewRows();
    expect(rows, hasLength(3));
    expect(rows.last.op, 'undo');
    expect(rows.last.cardId, isNull);
    expect(a.scheduler.ratedCalls.last, (_acc, 3));

    final second = rows[1];
    await a.repo.undo(_acc, deviceId: second.deviceId, seq: second.seq);
    expect(await a.schedule('c1'), isNull);
    // An undo of an event not seen here changes nothing.
    await a.repo.undo(_acc, deviceId: 'devX', seq: 9);
    expect(await a.reviewRows(), hasLength(5));
  });

  test(
      'two devices rate the same card offline; after a flush and a sync '
      'both count both reviews and show the same schedule', () async {
    final a = await _ReviewDevice.open(server, keys);
    final b = await _ReviewDevice.open(server, keys);
    a.offline = b.offline = true;

    await a.repo.rate(_acc, 'c1', Rating.good);
    b.now = a.now.add(const Duration(minutes: 3));
    await b.repo.rate(_acc, 'c1', Rating.again);
    // Offline: the segment is stored locally, its upload waits.
    expect(await a.uploader.flush(_acc), 1);
    await a.store.waitForIdle();
    expect(server.messagesIn(_dataPath), isEmpty);
    expect((await a.reviewRows()).single.segmentItemId, isNotNull);
    expect(await a.uploader.pendingAccounts(), isEmpty);

    a.offline = b.offline = false;
    expect(await b.uploader.flush(_acc), 1);
    await b.store.waitForIdle();
    await a.sync();
    await b.sync();
    await a.sync();

    expect(server.messagesIn(_dataPath), hasLength(2));
    for (final d in [a, b]) {
      final rows = await d.reviewRows();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.segmentItemId), everyElement(isNotNull));
      expect((await d.schedule('c1'))!.reps, 2);
    }
    expect(await a.schedule('c1'), await b.schedule('c1'));
    expect((await a.log.segments(_acc, reviewLogName)), hasLength(2));
    // Nothing left to write.
    expect(await a.uploader.flush(_acc), 0);
    expect(await b.uploader.flush(_acc), 0);
  });

  test(
      'a flush splits the pending reviews into segments of at most '
      '`maxEvents`', () async {
    final a = await _ReviewDevice.open(server, keys);
    for (var i = 0; i < 5; i++) {
      await a.repo.rate(_acc, 'c$i', Rating.good);
    }
    final uploader = ReviewUploader(a.db, a.log, maxEvents: 2);

    expect(await uploader.flush(_acc), 5);
    await a.store.waitForIdle();

    final segments = await a.log.segments(_acc, reviewLogName);
    expect(segments, hasLength(3));
    expect(await a.repo.pendingCount(_acc), 0);
    final events = await a.log.events(_acc, reviewLogName);
    expect([for (final e in events) e.seq], [1, 2, 3, 4, 5]);
  });

  test('without a write key the reviews stay pending', () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.repo.rate(_acc, 'c1', Rating.good);
    keys.byCollection.clear();

    expect(await a.uploader.flush(_acc), 0);
    expect((await a.reviewRows()).single.segmentItemId, isNull);
    expect(
      () => a.repo.setParams(_acc, FsrsParams()),
      throwsA(isA<NoWriteKeyException>()),
    );
  });

  test('after a restart the clock moves past pending own reviews', () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.repo.rate(_acc, 'c1', Rating.good);
    final deviceId = (await a.store.clockFor(_acc)).deviceId;
    // A rating stored right before the app died, before its high-water
    // marks reached the secure storage.
    final late = Hlc(a.now.millisecondsSinceEpoch + 60000, 5, deviceId);
    await a.db.into(a.db.reviewLog).insert(
          ReviewLogCompanion.insert(
            accountId: _acc,
            deviceId: deviceId,
            seq: 50,
            op: 'review',
            h: late.encode(),
            cardId: const Value('c1'),
            t: const Value(1),
            rating: const Value(3),
          ),
        );

    final restarted = a.restart();
    final clock = await restarted.store.clockFor(_acc);
    expect(clock.deviceId, deviceId);
    expect(clock.nextSeq(), 51);
    expect(clock.send() > late, isTrue);
  });

  test(
      'a change of deck options replays that deck; a change of fsrs.params '
      'replays every deck', () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.addCard('c1', 'deck-1');
    await a.addCard('c2', 'deck-2');
    await a.repo.rate(_acc, 'c1', Rating.good);
    await a.repo.rate(_acc, 'c2', Rating.good);
    await a.repo.rate(_acc, 'c3', Rating.good); // deck not known here
    final before = {
      for (final c in ['c1', 'c2', 'c3']) c: await a.schedule(c),
    };
    expect(await a.schedules.refreshParams(_acc), isEmpty);

    const options = DeckOptions(
      learningSteps: [Duration(hours: 1), Duration(hours: 2)],
    );
    await a.repo.setDeckOptions(_acc, 'deck-1', options);
    expect(await a.schedules.refreshParams(_acc), {'deck-1'});
    final c1 = (await a.schedule('c1'))!;
    expect(
      c1.dueMs,
      a.now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
    );
    expect(c1, isNot(before['c1']));
    expect(await a.schedule('c2'), before['c2']);
    expect(await a.schedule('c3'), before['c3']);
    expect(
      await a.paramsKey('c1'),
      paramsKeyOf(
        effectiveFsrsParams(
          {deckOptionsKey('deck-1'): options.toJson()},
          'deck-1',
        ),
      ),
    );
    expect(await a.schedules.refreshParams(_acc), isEmpty);

    await a.repo.setParams(_acc, FsrsParams(desiredRetention: 0.8));
    expect(
      await a.schedules.refreshParams(_acc),
      {'deck-1', 'deck-2', null},
    );
    expect(await a.schedules.refreshParams(_acc), isEmpty);
  });

  test('the params watch replays as soon as the device state changes',
      () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.addCard('c1', 'deck-1');
    await a.repo.rate(_acc, 'c1', Rating.good);
    final before = (await a.schedule('c1'))!;
    final sub = a.schedules.watchParams();
    addTearDown(sub.cancel);

    await a.repo.setDeckOptions(
      _acc,
      'deck-1',
      const DeckOptions(
        learningSteps: [Duration(hours: 3), Duration(hours: 4)],
      ),
    );

    final after = await a.repo
        .observeSchedule(_acc, 'c1')
        .firstWhere((s) => s != before)
        .timeout(const Duration(seconds: 5));
    expect(
      after!.dueMs,
      a.now.add(const Duration(hours: 4)).millisecondsSinceEpoch,
    );
  });

  test('a card arriving after its reviews is replayed with its deck options',
      () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.repo.setDeckOptions(
      _acc,
      'deck-1',
      const DeckOptions(learningSteps: [Duration(hours: 1)]),
    );
    await a.repo.rate(_acc, 'c9', Rating.again);
    final defaults = (await a.schedule('c9'))!;
    expect(
      defaults.dueMs,
      a.now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );

    final card = newCardObject(
      deckId: 'deck-1',
      cardId: 'c9',
      content: const CardContent(front: 'Q', back: 'A'),
      clock: await a.store.clockFor(_acc),
    );
    await CardDocProjector(a.db).apply(
      _acc,
      'hm-c9',
      ProjectedItem(display: card, heads: [card]),
    );

    expect(
      (await a.schedule('c9'))!.dueMs,
      a.now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
  });

  test('the due queue of a deck holds its reviewed cards due by then',
      () async {
    final a = await _ReviewDevice.open(server, keys);
    await a.addCard('c1', 'deck-1');
    await a.addCard('c2', 'deck-1');
    await a.addCard('c3', 'deck-2');
    await a.repo.rate(_acc, 'c1', Rating.again); // due in 1 min
    await a.repo.rate(_acc, 'c2', Rating.good); // due in 10 min
    await a.repo.rate(_acc, 'c3', Rating.again);
    final now = a.now.millisecondsSinceEpoch;

    Future<List<String>> due(int at) async => [
          for (final (id, _)
              in await a.repo.observeDue(_acc, 'deck-1', at).first)
            id,
        ];
    expect(await due(now), isEmpty);
    expect(await due(now + 60000), ['c1']);
    expect(await due(now + 600000), ['c1', 'c2']);
  });

  group('study counts (#1381)', () {
    const utc = FixedOffsetTimeZone(Duration.zero);
    const minute = 60000;

    /// A repository on [a]'s store whose study day is in UTC.
    ReviewRepositoryImpl utcRepo(_ReviewDevice a) => ReviewRepositoryImpl(
          a.db,
          a.store,
          deviceState: a.deviceState,
          schedules: CardScheduleWriter(a.db, tz: utc),
          now: () => a.now,
        );

    Future<void> card(
      _ReviewDevice a,
      String cardId,
      String deckId, {
      String h = 'h',
      bool deleted = false,
    }) =>
        a.db.into(a.db.cards).insert(
              CardsCompanion.insert(
                accountId: _acc,
                cardId: cardId,
                collectionId: deckId,
                sourceItemHmac: 'hm-$cardId',
                sourceKind: CardSourceKind.doc.name,
                h: h,
                deleted: Value(deleted),
              ),
            );

    test(
        'due, learning within the learn-ahead window and new per deck; '
        'deleted cards are not counted', () async {
      final a = await _ReviewDevice.open(server, keys);
      final repo = utcRepo(a);
      for (final id in ['c1', 'c2', 'c3', 'c5']) {
        await card(a, id, 'deck-1');
      }
      await card(a, 'gone', 'deck-1', deleted: true);
      await card(a, 'goneRated', 'deck-1', deleted: true);
      await card(a, 'c4', 'deck-2');
      await repo.rate(_acc, 'c1', Rating.good); // learning, due in 10 min
      await repo.rate(_acc, 'c2', Rating.again); // learning, due in 1 min
      await repo.rate(_acc, 'c3', Rating.easy); // review, due in days
      await repo.rate(_acc, 'goneRated', Rating.again);
      final now = a.now.millisecondsSinceEpoch;

      Future<Map<String, DeckCounts>> counts(int at) =>
          repo.observeDeckCounts(_acc, at).first;
      expect(await counts(now), {
        'deck-1': (due: 0, learning: 2, newCards: 1),
        'deck-2': (due: 0, learning: 0, newCards: 1),
      });
      // c1 is due 10 min from now: counted from 20 min before.
      final c1Ahead = now + 10 * minute - learnAhead.inMilliseconds;
      expect((await counts(c1Ahead))['deck-1']!.learning, 2);
      expect((await counts(c1Ahead - 1))['deck-1']!.learning, 1);
      final later = now + const Duration(days: 30).inMilliseconds;
      expect(
        (await counts(later))['deck-1'],
        (due: 1, learning: 2, newCards: 1),
      );
    });

    test(
        'the new cards: never reviewed, not deleted, in creation order, '
        'and an undo makes a card new again', () async {
      final a = await _ReviewDevice.open(server, keys);
      final repo = utcRepo(a);
      await card(a, 'b', 'deck-1', h: 'h2');
      await card(a, 'a', 'deck-1', h: 'h3');
      await card(a, 'c', 'deck-1', h: 'h1');
      await card(a, 'gone', 'deck-1', h: 'h0', deleted: true);
      await card(a, 'other', 'deck-2', h: 'h0');
      expect(await repo.observeNew(_acc, 'deck-1').first, ['c', 'b', 'a']);

      final event = await repo.rate(_acc, 'b', Rating.good);
      expect(await repo.observeNew(_acc, 'deck-1').first, ['c', 'a']);
      await repo.undo(_acc, deviceId: event.deviceId, seq: event.seq);
      expect(await repo.observeNew(_acc, 'deck-1').first, ['c', 'b', 'a']);
    });

    test(
        'newPerDay counts the first ratings since the study day started at '
        'dayStartHour; an undone first rating does not count', () async {
      final a = await _ReviewDevice.open(server, keys);
      final repo = utcRepo(a);
      for (final id in ['n1', 'n2', 'n3', 'n4']) {
        await card(a, id, 'deck-1');
      }
      expect(await repo.newLeftToday(_acc, 'deck-1'), 20);
      await repo.setDeckOptions(
        _acc,
        'deck-1',
        const DeckOptions(newPerDay: 2),
      );
      // 03:00 still belongs to the study day of yesterday.
      a.now = DateTime.utc(2026, 11, 2, 3);
      await repo.rate(_acc, 'n1', Rating.good);
      expect(await repo.newLeftToday(_acc, 'deck-1'), 1);

      a.now = DateTime.utc(2026, 11, 2, 4);
      expect(await repo.newLeftToday(_acc, 'deck-1'), 2);
      final n2 = await repo.rate(_acc, 'n2', Rating.good);
      // Not a first rating: n1 is not new any more.
      await repo.rate(_acc, 'n1', Rating.good);
      expect(await repo.newLeftToday(_acc, 'deck-1'), 1);
      final now = a.now.millisecondsSinceEpoch;
      expect(
        (await repo.observeDeckCounts(_acc, now).first)['deck-1']!.newCards,
        1,
      );

      await repo.undo(_acc, deviceId: n2.deviceId, seq: n2.seq);
      expect(await repo.newLeftToday(_acc, 'deck-1'), 2);
      // n2, n3 and n4 are new; at most 2 of them today.
      expect(
        (await repo.observeDeckCounts(_acc, now).first)['deck-1']!.newCards,
        2,
      );
      expect((await repo.deckParams(_acc, 'deck-1')).dayStartHour, 4);
    });
  });

  group('ReviewLogProjector', () {
    const remote = 'devR';
    ReviewEvent review(int seq, String cardId, int rating) => ReviewEvent(
          deviceId: remote,
          seq: seq,
          h: Hlc(1700000000000 + seq, 0, remote).encode(),
          cardId: cardId,
          t: 1700000000000 + seq * 60000,
          rating: rating,
        );
    UndoEvent undo(int seq, int refSeq) => UndoEvent(
          deviceId: remote,
          seq: seq,
          h: Hlc(1700000000000 + seq, 0, remote).encode(),
          refDeviceId: remote,
          refSeq: refSeq,
        );

    test('remote events are stored once, unknown ops skipped, undos applied',
        () async {
      final a = await _ReviewDevice.open(server, keys);
      final projector = ReviewLogProjector(a.db);
      final segment = [
        _wire(review(1, 'c1', 3)),
        LogEvent(
          seq: 2,
          hlc: Hlc(1700000000002, 0, remote),
          json: {'op': 'flag', 'c': 'c1'},
        ),
        _wire(review(3, 'c1', 1)),
      ];

      await projector.apply(_acc, 'seg-1', segment);
      await projector.apply(_acc, 'seg-1', segment);
      await projector.apply(_acc, 'pack-1', segment);

      final rows = await a.reviewRows();
      expect(rows.map((r) => r.seq), [1, 3]);
      expect(rows.map((r) => r.segmentItemId), ['seg-1', 'seg-1']);
      expect((await a.schedule('c1'))!.reps, 2);

      await projector.apply(_acc, 'seg-2', [_wire(undo(4, 3))]);
      expect((await a.schedule('c1'))!.reps, 1);
      await projector.apply(_acc, 'seg-3', [_wire(undo(5, 1))]);
      expect(await a.schedule('c1'), isNull);
    });

    test('an undo arriving before its review cancels it once it arrives',
        () async {
      final a = await _ReviewDevice.open(server, keys);
      final projector = ReviewLogProjector(a.db);

      await projector.apply(_acc, 'seg-2', [_wire(undo(2, 1))]);
      expect(await a.schedule('c1'), isNull);
      await projector.apply(_acc, 'seg-1', [_wire(review(1, 'c1', 3))]);
      expect(await a.schedule('c1'), isNull);
      await projector.apply(_acc, 'seg-3', [_wire(review(3, 'c1', 3))]);
      expect((await a.schedule('c1'))!.reps, 1);
    });
  });
}
