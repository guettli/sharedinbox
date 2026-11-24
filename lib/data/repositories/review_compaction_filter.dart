import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Which events a `review` pack keeps (ENCRYPTED-OBJECTS.md §7, #1382): the
/// reviews of a card with a synced tombstone are dropped, and so are the
/// undos of those reviews. A tombstone is synced when the `Cards` row is
/// `deleted` and the `mail_objects` row of its winning `card` tombstone is
/// confirmed: not pending upload and with a server id (an IMAP UID or a
/// JMAP id). Local `review_log` rows are never touched.
class ReviewCompactionFilter {
  ReviewCompactionFilter(this.db);

  final AppDatabase db;

  /// The filter for the next pack of [accountId], from what is stored now.
  Future<bool Function(LogEvent event)> load(String accountId) async {
    final cards = await syncedTombstones(accountId);
    if (cards.isEmpty) return (_) => true;
    final dropped = await _reviewsOf(accountId, cards);
    return (event) => switch (CardEvent.fromLogEvent(event)) {
          ReviewEvent(:final cardId) => !cards.contains(cardId),
          UndoEvent(:final refDeviceId, :final refSeq) =>
            !dropped.contains((refDeviceId, refSeq)),
          null => true,
        };
  }

  /// The cardIds of [accountId] with a synced tombstone.
  Future<Set<String>> syncedTombstones(String accountId) async {
    final query = db.select(db.cards).join([
      innerJoin(
        db.mailObjects,
        db.mailObjects.accountId.equalsExp(db.cards.accountId) &
            db.mailObjects.folder.equals(MailObjectFolder.data.name) &
            db.mailObjects.itemHmac.equalsExp(db.cards.sourceItemHmac) &
            db.mailObjects.versionId.equalsExp(db.cards.h),
      ),
    ])
      ..where(
        db.cards.accountId.equals(accountId) &
            db.cards.deleted.equals(true) &
            db.mailObjects.pendingUpload.equals(false) &
            db.mailObjects.serverId.isNotNull(),
      );
    return {for (final r in await query.get()) r.readTable(db.cards).cardId};
  }

  /// `(deviceId, seq)` of the reviews of [cards] seen here.
  Future<Set<(String, int)>> _reviewsOf(
    String accountId,
    Set<String> cards,
  ) async =>
      {
        for (final r in await (db.select(db.reviewLog)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.op.equals('review') &
                    t.cardId.isIn(cards),
              ))
            .get())
          (r.deviceId, r.seq),
      };
}
