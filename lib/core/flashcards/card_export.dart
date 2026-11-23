import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/card.dart';

/// The flash card files of the export (ENCRYPTED-OBJECTS.md §7, #1380):
/// pure serializers; the export (#1356) puts them into its ZIP.

/// The header of [cardsCsv].
const cardsCsvHeader = [
  'cardId',
  'deckId',
  'deckName',
  'front',
  'back',
  'tags',
  'h',
];

final _imageRef = RegExp(r'si-img:([A-Za-z0-9_-]+)');

/// The cards as CSV (RFC 4180: CRLF line ends, fields with a comma, quote
/// or line break quoted): one row per card, tags separated by spaces. An
/// image reference `si-img:<itemId>` becomes `media/<itemId>`; [media]
/// lists those itemIds once each, in order, for the ZIP writer to add.
({String csv, List<String> media}) cardsCsv(
  Iterable<Deck> decks,
  Iterable<FlashCard> cards,
) {
  final names = {for (final d in decks) d.deckId: d.name};
  final media = <String>{};
  String rewrite(String markdown) => markdown.replaceAllMapped(_imageRef, (m) {
        media.add(m[1]!);
        return 'media/${m[1]}';
      });

  final lines = [
    _csvLine(cardsCsvHeader),
    for (final c in cards)
      _csvLine([
        c.cardId,
        c.deckId,
        names[c.deckId] ?? '',
        rewrite(c.front),
        rewrite(c.back),
        c.tags.join(' '),
        c.h,
      ]),
  ];
  return (csv: lines.join(), media: media.toList());
}

/// The review log as JSONL: one wire event (`CardEvent.toJson`) plus its
/// `device` per line, ordered by `(h, deviceId, seq)`.
String reviewLogJsonl(Iterable<CardEvent> events) {
  final sorted = [...events]..sort((a, b) {
      final byH = a.h.compareTo(b.h);
      if (byH != 0) return byH;
      final byDevice = a.deviceId.compareTo(b.deviceId);
      return byDevice != 0 ? byDevice : a.seq.compareTo(b.seq);
    });
  return [
    for (final e in sorted)
      '${canonicalJson({...e.toJson(), 'device': e.deviceId})}\n',
  ].join();
}

String _csvLine(List<String> fields) =>
    '${fields.map(_csvField).join(',')}\r\n';

String _csvField(String value) {
  if (!value.contains(RegExp('[",\r\n]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}
