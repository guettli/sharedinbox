import 'dart:async';
import 'dart:typed_data';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/card_repository.dart';
import 'package:sharedinbox/core/repositories/review_repository.dart';

/// A deck of acc-1 named [name].
Deck testDeck(String deckId, String name, {bool hasConflict = false}) => Deck(
      accountId: 'acc-1',
      deckId: deckId,
      itemHmac: 'hm-$deckId',
      name: name,
      versionId: 'v',
      updatedAt: DateTime.utc(2026, 11, 23),
      hasConflict: hasConflict,
    );

/// A card of acc-1 in [deckId].
FlashCard testCard(String cardId, String deckId, String front, String back) =>
    FlashCard(
      accountId: 'acc-1',
      cardId: cardId,
      deckId: deckId,
      content: CardContent(front: front, back: back),
      h: 'h-$cardId',
      sourceItemHmac: 'hm-$cardId',
      sourceKind: CardSourceKind.doc,
    );

/// In-memory [CardRepository]; records the writes.
class FakeCardRepository implements CardRepository {
  FakeCardRepository({
    List<Deck> decks = const [],
    List<FlashCard> cards = const [],
  })  : _decks = List.of(decks),
        _cards = List.of(cards);

  final List<Deck> _decks;
  final List<FlashCard> _cards;
  final _changes = StreamController<void>.broadcast();
  final added = <({String deckId, CardContent content})>[];
  final deleted = <String>[];
  final renamed = <(String, String)>[];

  /// Thrown by the next write, if set.
  Object? failWith;

  void _write() {
    final fail = failWith;
    if (fail == null) return;
    failWith = null;
    throw fail;
  }

  List<Deck> _sorted() =>
      List.of(_decks)..sort((a, b) => a.name.compareTo(b.name));

  @override
  Stream<List<Deck>> observeDecks(String accountId) async* {
    yield _sorted();
    yield* _changes.stream.map((_) => _sorted());
  }

  List<FlashCard> _of(String deckId) => [
        for (final c in _cards)
          if (c.deckId == deckId) c,
      ];

  @override
  Stream<List<FlashCard>> observeCards(String accountId, String deckId) async* {
    yield _of(deckId);
    yield* _changes.stream.map((_) => _of(deckId));
  }

  @override
  Future<FlashCard?> card(String accountId, String cardId) async =>
      _cards.where((c) => c.cardId == cardId).firstOrNull;

  @override
  Future<Deck> createDeck(String accountId, String name) async {
    _write();
    final deck = testDeck('deck-new${_decks.length}', name);
    _decks.add(deck);
    _changes.add(null);
    return deck;
  }

  @override
  Future<void> renameDeck(String accountId, String deckId, String name) async {
    _write();
    renamed.add((deckId, name));
    final i = _decks.indexWhere((d) => d.deckId == deckId);
    _decks[i] = testDeck(deckId, name);
    _changes.add(null);
  }

  @override
  Future<int> cardCount(String accountId, String deckId) async =>
      _of(deckId).length;

  @override
  Future<void> deleteDeck(String accountId, String deckId) async {
    _write();
    deleted.add(deckId);
    _decks.removeWhere((d) => d.deckId == deckId);
    _cards.removeWhere((c) => c.deckId == deckId);
    _changes.add(null);
  }

  @override
  Future<FlashCard> addCard(
    String accountId,
    String deckId,
    NewCard card,
  ) async {
    _write();
    added.add((deckId: deckId, content: card.content));
    final c = testCard(
      'new${_cards.length}',
      deckId,
      card.content.front,
      card.content.back,
    );
    _cards.add(c);
    _changes.add(null);
    return c;
  }

  @override
  Future<List<String>> importCards(
    String accountId,
    String deckId,
    List<NewCard> cards,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> editCard(
    String accountId,
    String cardId,
    CardContent content,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> deleteCard(String accountId, String cardId) =>
      throw UnimplementedError();

  @override
  Future<void> rewriteBatch(
    String accountId,
    String batchItemHmac,
    Map<String, CardContent> changes,
  ) =>
      throw UnimplementedError();
}

/// A [ReviewRepository] with fixed due and new cards; records ratings,
/// undos and session ends.
class FakeReviewRepository implements ReviewRepository {
  FakeReviewRepository({
    this.due = const [],
    this.newIds = const [],
    this.newLeft = 20,
    this.counts = const {},
  });

  final List<(String, CardSchedule)> due;
  final List<String> newIds;
  final int newLeft;
  final Map<String, DeckCounts> counts;

  final rated = <({String cardId, Rating rating, int durationMs})>[];
  final undone = <(String, int)>[];
  final sessionsEnded = <String>[];
  int _seq = 0;

  /// Thrown by the next [rate], if set.
  Object? failRateWith;

  @override
  Future<ReviewEvent> rate(
    String accountId,
    String cardId,
    Rating rating, {
    int durationMs = 0,
  }) async {
    final fail = failRateWith;
    if (fail != null) {
      failRateWith = null;
      throw fail;
    }
    rated.add((cardId: cardId, rating: rating, durationMs: durationMs));
    final seq = ++_seq;
    return ReviewEvent(
      deviceId: 'dev',
      seq: seq,
      h: 'h$seq',
      cardId: cardId,
      t: 0,
      rating: rating.value,
      ms: durationMs,
    );
  }

  @override
  Future<UndoEvent> undo(
    String accountId, {
    required String deviceId,
    required int seq,
  }) async {
    undone.add((deviceId, seq));
    return UndoEvent(
      deviceId: 'dev',
      seq: ++_seq,
      h: 'h$_seq',
      refDeviceId: deviceId,
      refSeq: seq,
    );
  }

  @override
  Stream<List<(String, CardSchedule)>> observeDue(
    String accountId,
    String deckId,
    int nowMs,
  ) =>
      Stream.value([
        for (final d in due)
          if (d.$2.dueMs <= nowMs) d,
      ]);

  @override
  Stream<List<String>> observeNew(String accountId, String deckId) =>
      Stream.value(newIds);

  @override
  Stream<Map<String, DeckCounts>> observeDeckCounts(
    String accountId,
    int nowMs,
  ) =>
      Stream.value(counts);

  @override
  Future<FsrsParams> deckParams(String accountId, String deckId) async =>
      FsrsParams(enableFuzz: false);

  @override
  Future<int> newLeftToday(String accountId, String deckId) async => newLeft;

  @override
  void endSession(String accountId) => sessionsEnded.add(accountId);

  @override
  Future<void> setParams(String accountId, FsrsParams params) =>
      throw UnimplementedError();

  @override
  Future<void> setDeckOptions(
    String accountId,
    String deckId,
    DeckOptions options,
  ) =>
      throw UnimplementedError();

  @override
  Stream<CardSchedule?> observeSchedule(String accountId, String cardId) =>
      throw UnimplementedError();
}

/// A [CardImporter] returning [result] or throwing [error].
class FakeCardImporter implements CardImporter {
  FakeCardImporter({this.result = const ImportResult(), this.error});

  final ImportResult result;
  final Object? error;
  final apkg = <int>[];
  final csv = <String>[];

  @override
  Future<ImportResult> importApkg(String accountId, Uint8List bytes) async {
    apkg.add(bytes.length);
    if (error case final e?) throw e;
    return result;
  }

  @override
  Future<ImportResult> importCsv(String accountId, String text) async {
    csv.add(text);
    if (error case final e?) throw e;
    return result;
  }
}
