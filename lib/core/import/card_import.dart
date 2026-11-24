import 'dart:typed_data';

import 'package:sharedinbox/core/models/card.dart';

/// One card read from an import file (#1383), with its stable cardId
/// (`import_ids.dart`) and the name of its deck (Anki keeps the `::`
/// hierarchy in it).
class ImportedCard {
  const ImportedCard({
    required this.cardId,
    required this.deckName,
    required this.content,
  });

  final String cardId;
  final String deckName;
  final CardContent content;
}

/// What an import did.
class ImportResult {
  const ImportResult({
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.skippedDeleted = 0,
    this.skippedCloze = 0,
    this.skippedEmpty = 0,
    this.missingMedia = 0,
    this.droppedSounds = 0,
    this.reviewsAdded = 0,
    this.reviewsKnown = 0,
    this.skippedReviews = 0,
    this.decks = const [],
  });

  /// Cards that were not known yet.
  final int added;

  /// Known cards whose content differed: the file wins.
  final int updated;

  /// Known cards with the same content: not written.
  final int unchanged;

  /// Cards deleted here: an import does not bring them back.
  final int skippedDeleted;

  /// Anki cloze notes (not supported yet).
  final int skippedCloze;

  /// Rows or cards without a front.
  final int skippedEmpty;

  /// Referenced images that are not in the file (or too large to store).
  final int missingMedia;

  /// `[sound:…]` references, dropped.
  final int droppedSounds;

  /// Review events of the history (#1385) that were not known yet.
  final int reviewsAdded;

  /// Review events known already (a re-import): not written.
  final int reviewsKnown;

  /// Review history rows that are no review event: manual and rescheduled
  /// rows, rows up to a reset, rows of cards not imported or deleted here.
  final int skippedReviews;

  /// The names of the decks the cards went to.
  final List<String> decks;

  @override
  String toString() => 'ImportResult(added: $added, updated: $updated, '
      'unchanged: $unchanged, skippedDeleted: $skippedDeleted, '
      'skippedCloze: $skippedCloze, skippedEmpty: $skippedEmpty, '
      'missingMedia: $missingMedia, droppedSounds: $droppedSounds, '
      'reviewsAdded: $reviewsAdded, reviewsKnown: $reviewsKnown, '
      'skippedReviews: $skippedReviews, decks: $decks)';
}

/// The `.apkg` holds only a format this app cannot read yet (for example
/// only `collection.anki21b`, #1384).
class UnsupportedAnkiFormatException implements Exception {
  const UnsupportedAnkiFormatException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedAnkiFormatException: $message';
}

/// Imports flash cards from Anki `.apkg` and CSV files into the decks of an
/// account (ENCRYPTED-OBJECTS.md §7, #1383), and the review history of an
/// `.apkg` (#1385). Importing the same file again adds nothing twice:
/// unchanged cards stay, changed ones are updated, cards deleted here stay
/// deleted, and known review events are not written again. Works offline (the normal sync uploads
/// the cards); throws `NoWriteKeyException` while the account is locked.
abstract class CardImporter {
  /// Imports an Anki `.apkg` (`collection.anki21` or `collection.anki2`).
  /// Throws [UnsupportedAnkiFormatException] and [FormatException].
  Future<ImportResult> importApkg(String accountId, Uint8List bytes);

  /// Imports CSV rows `front, back, tags, deck`.
  Future<ImportResult> importCsv(String accountId, String text);
}
