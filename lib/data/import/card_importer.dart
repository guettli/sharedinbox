import 'dart:async';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart'
    show ObjectTooLargeException;
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/csv_cards.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/card_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/import/anki_apkg_reader.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';

/// [CardImporter] over the [CardRepository] and the [MailObjectBlobStore]
/// (#1383). Each card is looked up by its stable cardId: a deleted one is
/// skipped, an unchanged one is not written, a changed one gets a new batch
/// member (whose fresh `h` wins over the old version) in the deck it is in,
/// an unknown one is added to the deck of its name (created if needed).
/// Images are stored once per deck under their content address, before
/// the cards that show them.
class CardImporterImpl implements CardImporter {
  CardImporterImpl(this._cards, this._blobs, {AppLogger? appLogger})
      : _appLogger = appLogger;

  final CardRepository _cards;
  final MailObjectBlobStore _blobs;
  final AppLogger? _appLogger;

  @override
  Future<ImportResult> importApkg(String accountId, Uint8List bytes) async {
    final anki = await readApkg(bytes);
    if (anki.missingMedia.isNotEmpty) {
      _log(
        accountId,
        'card_import.missing_media',
        'Images referenced by the .apkg are not in it',
        {'files': anki.missingMedia},
      );
    }
    if (anki.droppedSounds > 0) {
      _log(
        accountId,
        'card_import.sounds_dropped',
        'Sound references of the .apkg are dropped',
        {'count': anki.droppedSounds},
      );
    }
    final result = await _import(accountId, anki.cards, anki.media);
    return ImportResult(
      added: result.added,
      updated: result.updated,
      unchanged: result.unchanged,
      skippedDeleted: result.skippedDeleted,
      skippedCloze: anki.skippedCloze,
      skippedEmpty: anki.skippedEmpty,
      missingMedia: anki.missingMedia.length + result.missingMedia,
      droppedSounds: anki.droppedSounds,
      decks: result.decks,
    );
  }

  @override
  Future<ImportResult> importCsv(String accountId, String text) async {
    final csv = parseCsvCards(text);
    final result = await _import(accountId, csv.cards, const {});
    return ImportResult(
      added: result.added,
      updated: result.updated,
      unchanged: result.unchanged,
      skippedDeleted: result.skippedDeleted,
      skippedEmpty: csv.skippedEmpty,
      decks: result.decks,
    );
  }

  Future<ImportResult> _import(
    String accountId,
    List<ImportedCard> imported,
    Map<String, ({Uint8List bytes, String contentType})> media,
  ) async {
    final known = await _cards.observeDecks(accountId).first;
    final deckIdByName = <String, String>{};
    for (final d in known) {
      deckIdByName.putIfAbsent(d.name, () => d.deckId);
    }
    final deckNameById = {for (final d in known) d.deckId: d.name};
    Future<String> deckFor(String name) async {
      if (deckIdByName[name] case final id?) return id;
      final deck = await _cards.createDeck(accountId, name);
      deckNameById[deck.deckId] = name;
      return deckIdByName[name] = deck.deckId;
    }

    // The same cardId twice in a file (a CSV row repeated): the last wins.
    final byId = {for (final c in imported) c.cardId: c};
    final writes = <String, List<NewCard>>{};
    var added = 0;
    var updated = 0;
    var unchanged = 0;
    var deleted = 0;
    for (final c in byId.values) {
      final String deckId;
      switch (await _cards.cardState(accountId, c.cardId)) {
        case CardDeleted():
          deleted++;
          continue;
        case CardLive(:final card) when card.content == c.content:
          unchanged++;
          continue;
        case CardLive(:final card):
          updated++;
          deckId = card.deckId;
          if (deckNameById[deckId] != c.deckName) {
            _log(
              accountId,
              'card_import.other_deck',
              'An imported card stays in the deck it is in',
              {'cardId': c.cardId, 'deck': deckNameById[deckId]},
            );
          }
        case CardUnknown():
          added++;
          deckId = await deckFor(c.deckName);
      }
      (writes[deckId] ??= []).add(NewCard(c.content, cardId: c.cardId));
    }

    var tooLarge = 0;
    for (final MapEntry(key: deckId, value: cards) in writes.entries) {
      final blobIds = {
        for (final card in cards)
          for (final m in _blobRef.allMatches(
            '${card.content.front}\n${card.content.back}',
          ))
            m.group(1)!,
      };
      for (final id in blobIds) {
        final blob = media[id];
        if (blob == null) continue;
        try {
          await _blobs.putBlob(
            accountId,
            deckId,
            blob.bytes,
            blob.contentType,
            itemId: id,
          );
        } on ObjectTooLargeException catch (e) {
          tooLarge++;
          _log(
            accountId,
            'card_import.media_too_large',
            'An image of the import is too large to store',
            {'blobId': id, 'size': blob.bytes.length, 'error': '$e'},
          );
        }
      }
      await _cards.importCards(accountId, deckId, cards);
    }

    return ImportResult(
      added: added,
      updated: updated,
      unchanged: unchanged,
      skippedDeleted: deleted,
      missingMedia: tooLarge,
      decks: {for (final c in byId.values) c.deckName}.toList(),
    );
  }

  void _log(
    String accountId,
    String event,
    String message,
    Map<String, Object?> data,
  ) =>
      unawaited(
        _appLogger?.info(event, message, accountId: accountId, data: data),
      );
}

final _blobRef = RegExp(r'si-img:([A-Za-z0-9_-]+)');
