// Backend test for flash card reviews (#1380) against a real Stalwart: two
// devices of one account, the key set up on A and unlocked on B with the
// recovery key. Both rate the same card while neither has seen the other's
// review; after a flush and a sync each counts both reviews, both show the
// same schedule, and the server holds one `review-seg` per device. A rating
// itself never touches the server.
// Run via: task test-backend

import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_log_projector.dart';
import 'package:sharedinbox/data/repositories/review_repository_impl.dart';
import 'package:sharedinbox/data/repositories/review_uploader.dart';
import 'package:test/test.dart';

import 'key_device_harness.dart';

void main() {
  final pool = setUpKeyPool();

  Future<_ReviewDevice> device() =>
      addKeyDevice(pool(), _ReviewDevice(pool().account));

  test(
      'two devices review the same card offline: both reviews count, the '
      'schedule is the same on both, one review-seg per device', () async {
    final a = await device();
    final created = await a.service.createKey(a.id) as KeyCreated;
    final deck = await a.cards.createDeck(a.id, 'Spanish');
    final cardId = (await a.cards.importCards(
      a.id,
      deck.deckId,
      const [NewCard(CardContent(front: 'hola', back: 'hello'))],
    ))
        .single;
    await a.store.waitForIdle();
    await a.listAndSync();
    final b = await device();
    await b.listAndSync();
    await b.service.unlockWithRecoveryKey(b.id, created.formatted);
    await b.listAndSync();
    expect(await b.cards.card(b.id, cardId), isNotNull);
    final mailsBefore = (await pool().rawMails(dataPath)).length;

    // No flush in between: neither device has the other's review.
    await a.reviews.rate(a.id, cardId, Rating.good);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.reviews.rate(b.id, cardId, Rating.again);
    await a.store.waitForIdle();
    await b.store.waitForIdle();
    expect(await pool().rawMails(dataPath), hasLength(mailsBefore));
    for (final d in [a, b]) {
      expect((await d.reviews.observeSchedule(d.id, cardId).first)!.reps, 1);
    }

    for (final d in [a, b]) {
      expect(await d.uploader.flush(d.id), 1);
      await d.store.waitForIdle();
      await d.listAndSync();
    }
    await a.listAndSync();
    await b.listAndSync();

    final onA = await a.reviews.observeSchedule(a.id, cardId).first;
    final onB = await b.reviews.observeSchedule(b.id, cardId).first;
    expect(onA!.reps, 2);
    expect(onB, onA);
    for (final d in [a, b]) {
      final rows = await d.db.select(d.db.reviewLog).get();
      expect(rows, hasLength(2));
      expect({for (final r in rows) r.deviceId}, hasLength(2));
      expect(rows.map((r) => r.segmentItemId), everyElement(isNotNull));
    }
    final segments = await a.log.segments(a.id, reviewLogName);
    expect(segments.map((s) => s.kind), everyElement(segKind(reviewLogName)));
    expect(segments, hasLength(2));
    expect(
      (await pool().rawMails(dataPath)).keys,
      containsAll([for (final s in segments) s.messageId]),
    );
    expect(await pool().rawMails(dataPath), hasLength(mailsBefore + 2));
  });
}

/// A [KeyDevice] whose store writes the card and review projections, with
/// the card and review repositories on top.
class _ReviewDevice extends ProjectingKeyDevice {
  _ReviewDevice(super.account)
      : super(
          projectors: (db) => [
            CardDocProjector(db),
            CardBatchProjector(db),
            DeckProjector(db),
            ReviewLogProjector(db),
          ],
        );

  late final cards = CardRepositoryImpl(
    db,
    store,
    ensureCollection: service.ensureCollection,
  );
  late final log = MailObjectLog(db, store);
  late final uploader = ReviewUploader(db, log);
  late final reviews = ReviewRepositoryImpl(
    db,
    store,
    deviceState: DeviceStateStore(db, store),
  );
}
