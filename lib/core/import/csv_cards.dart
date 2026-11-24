import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/models/card.dart';

/// The deck of a CSV row without one.
const defaultDeck = 'Default';

/// The cards of a CSV file (#1383) and the rows skipped for an empty front.
class CsvCards {
  const CsvCards(this.cards, {this.skippedEmpty = 0});

  final List<ImportedCard> cards;
  final int skippedEmpty;
}

/// Reads CSV [text] (RFC 4180: quoted fields with `""` escapes, commas and
/// line breaks inside quotes, `\n` or `\r\n`, an optional UTF-8 BOM) with
/// the columns `front, back, tags, deck`. A header row (`front,back,…`, any
/// case) is skipped; tags are split on whitespace; an empty deck is
/// [defaultDeck]. The cardId is [csvCardId] of deck and front, so a later
/// import of the same file updates the same cards. The text is only data:
/// nothing in it is interpreted.
CsvCards parseCsvCards(String text) {
  final rows = parseCsv(text);
  if (rows.isNotEmpty && _isHeader(rows.first)) rows.removeAt(0);
  final cards = <ImportedCard>[];
  var skipped = 0;
  for (final row in rows) {
    String col(int i) => i < row.length ? row[i].trim() : '';
    if (row.every((f) => f.trim().isEmpty)) continue;
    final front = col(0);
    if (front.isEmpty) {
      skipped++;
      continue;
    }
    final deck = col(3).isEmpty ? defaultDeck : col(3);
    cards.add(
      ImportedCard(
        cardId: csvCardId(deck, front),
        deckName: deck,
        content: CardContent(
          front: front,
          back: col(1),
          tags:
              col(2).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(),
        ),
      ),
    );
  }
  return CsvCards(cards, skippedEmpty: skipped);
}

bool _isHeader(List<String> row) =>
    row.length >= 2 &&
    row[0].trim().toLowerCase() == 'front' &&
    row[1].trim().toLowerCase() == 'back';

/// The rows of CSV [text] (RFC 4180), each a list of its fields. A trailing
/// line break does not add an empty row.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = text.startsWith('﻿') ? 1 : 0;

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];
    i++;
    if (quoted) {
      if (c != '"') {
        field.write(c);
        continue;
      }
      if (i < text.length && text[i] == '"') {
        field.write('"');
        i++;
        continue;
      }
      quoted = false;
      continue;
    }
    switch (c) {
      case '"':
        quoted = true;
      case ',':
        endField();
      case '\r':
        if (i < text.length && text[i] == '\n') i++;
        endRow();
      case '\n':
        endRow();
      default:
        field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
