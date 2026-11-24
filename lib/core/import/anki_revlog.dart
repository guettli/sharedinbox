import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';

/// One row of the Anki `revlog` (#1385), with the cardId of its card
/// (`import_ids.dart`); [cardId] null: the card is not imported (a cloze
/// or empty card, or a cid without a card).
class AnkiRevlogRow {
  const AnkiRevlogRow({
    required this.id,
    required this.cardId,
    required this.ease,
    required this.time,
    required this.type,
    required this.ivl,
  });

  /// Epoch ms of the review; unique per collection.
  final int id;
  final String? cardId;

  /// 1 (again) … 4 (easy); 0 for a manual entry.
  final int ease;

  /// How long the review took, in milliseconds.
  final int time;

  /// 0 learn, 1 review, 2 relearn, 3 filtered (cram), 4 manual,
  /// 5 rescheduled.
  final int type;
  final int ivl;

  /// A "Forget" / reset of the card: its history before it no longer
  /// counts (as for Anki's own FSRS).
  bool get isReset => type == 4 && ease == 0 && ivl == 0;
}

/// The review events of the Anki review history [rows], written as
/// [deviceId] (`ankiImportDeviceId`): `seq` = `t` = the revlog id, `h` the
/// HLC `(id, 0, deviceId)`, so the imported history sorts before later
/// local reviews. Per card the rows up to and including its last reset are
/// dropped; of the rest only learn, review, relearn and filtered rows
/// (`type` 0–3) with a rating 1–4 are kept. [skipped] counts every row
/// that is not an event.
({List<ReviewEvent> events, int skipped}) ankiReviewEvents(
  String deviceId,
  Iterable<AnkiRevlogRow> rows,
) {
  final all = rows.toList();
  final lastReset = <String, int>{};
  for (final r in all) {
    final cardId = r.cardId;
    if (cardId == null || !r.isReset) continue;
    if (r.id > (lastReset[cardId] ?? -1)) lastReset[cardId] = r.id;
  }
  final events = <ReviewEvent>[];
  var skipped = 0;
  for (final r in all) {
    final cardId = r.cardId;
    if (cardId == null ||
        r.id <= (lastReset[cardId] ?? 0) ||
        r.type < 0 ||
        r.type > 3 ||
        r.ease < 1 ||
        r.ease > 4 ||
        r.id > Hlc.maxWallMs) {
      skipped++;
      continue;
    }
    events.add(
      ReviewEvent(
        deviceId: deviceId,
        seq: r.id,
        h: Hlc(r.id, 0, deviceId).encode(),
        cardId: cardId,
        t: r.id,
        rating: r.ease,
        ms: r.time < 0 ? 0 : r.time,
      ),
    );
  }
  events.sort((a, b) => a.seq.compareTo(b.seq));
  return (events: events, skipped: skipped);
}
